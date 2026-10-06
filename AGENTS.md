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

When a departure from real emacs functionality is found, it's better to look at
the code and copy it than try and test its functionality. Testing it gets a
simplistic view of how it works that copying its actual code solves. Testing
it is a last resort when copying should be the main method of finding and repeating
real emacs functionality.

Never implement an emacs function without implementing all the more primitive 
functions it depends on. That just results in something half assed that has
to be rewritten later. If you have to implement something, start from the bottom
implementing each primtive in turn that the function needs and work your way
up until the final function works, and it works exactly the same as emacs because
it is built up from exactly the same primitives.

When there is a bug, and the user complains about the behavior, never just put in
what you think the fix should be, what you should do is find out how our implementation
departed from real emacs, and fix that departure. If you start improvising fixes,
you'll get subtley different behavior that will manifest itself later down the track. 
That's not good. 

There are two front ends, the ncurses one and the gtk one. That makes it 
necessary to be very careful when you are fixing a bug to make sure you fix it
at the right level of abstraction or you risk fixing one front end and breaking
the other one, or at least only fixing one when maybe it should have been both.

Most of your testing should be by connecting remotely to the editor
via the REPL and entering commands directly. Unless part of the task
is actually testing key bindings or something, testing via the REPL
and calling the commands directly to drive the editor is the preferred
way to do it.

If you get into a muddle chasing mismatched parenthesis, don't waste too many tokens
chasing it down. Have a few attempts, then stop and get assistence from the user.
I dont like seeing AI wasting hours hunting down a parenthesis mismatch that the user
could easily fix.

If you get into a mess with either bad behavior or super large functions,
always check yourself... does real emcas have a function this messy or this big?
Sometimes it does, and it is what it is. But sometimes you make a mess of it
and try to patch it when you should go back to emacs itself and start afresh.

If our behavior differs to real emacs, don't just figure it out empirically,
look at the emacs code to find out definitively the rule.

If Emacs implements an algorithm in several functions, you should too. Don't
try and mash it into one.

If you find an emacs function that uses a primitive that we don't have.
Don't try and paper over it by getting around it. It's your job to find that
primitive, port that primitve and make sure our entire code base uses that
primitive the same way emacs does.

Of course, we don't want to fully port code that exists in guile itself or
a guile library we can download. In that case the answer is to integrate core
guile functions and/or find the right library. When I say port every primitive
I mean in functionality, occasionally that porting might mean substiuting 
functions that already exist in scheme or guile.

If you find yourself trying to debug code, you're probably better off looking
at the emacs code to see how you departed from it, rather than trying to reason
about why it doesn't work. The emacs code works, so if you ported it faithfully,
yours will work too. Where you get bugs is mostly where you try to wander off
your own way. Many times you found that you were chasing rabbit holes of bugs
but when you read the emacs source you landed it first time.

You will most likely find full emacs sources at @../emacs/

A piece of work isn't done till you fix most of the warnings. There are a
few warnings that we can't avoid, those are fine, but all the ones we
can fix should be fixed before a piece of work is complete.

After every piece of work, report anything you did or anything you found
that is a departure from real emacs. Give insight on whether that departure
should be fixed.


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


# Handoff — the replace, quoted-insert and file-command pass (2026-10-02)

## What landed

BASIC-FUNC.md groups 11-15, per the plan in
`/home/chris/.claude/plans/buzzing-napping-summit.md`:

- **`schemacs/editor/search.sld`** (NEW, mirrors search.c): `string-match`,
  `looking-at`, `looking-back`, `re-search-forward/backward`,
  `search-forward/backward` (MOVED here from editfns.sld - they are
  search.c's DEFUNs; sole other importer is minibuffer.sld's
  `zap-to-char`), `match-data`/`set-match-data`/`match-beginning`/
  `match-end`/`match-data--translate`, `replace-match` (string and
  buffer paths, case transfer per search.c:2406-2510), `regexp-quote`,
  `match-string`, `save-match-data` (a macro). The REGEXP ENGINE is
  Guile's - `(ice-9 regex)`, glibc ERE - over which `%emacs-ere'
  translates: Emacs's `\( \) \| \{n,m\} \? \+` spellings swap to ERE's,
  ERE's specials escape, `\w \b \< \> \1-\9 [[:digit:]]` pass through
  (glibc has them), `\sX \Sx \cX \C \= \_ \` \'` are rejected with an
  error. Named deviations: leftmost-LONGEST (POSIX) vs leftmost-FIRST
  (Emacs); shy groups renumber. Note `make-regexp`/`regexp-exec`/the
  `regexp/*' flags are Guile CORE names, NOT `(ice-9 regex)''s - that
  library only exports the `match:*' accessors and the sugar.
- **`schemacs/editor/replace.sld`** (NEW, mirrors replace.el): the full
  `perform-replace' - every answer y/n/Y/N/!/./,/q/RET/DEL/^/u/U/C-r/
  C-w/e/E/C-l/C-v/M-v/C-g plus the default pushback - the stack, the
  highlight via `*search-highlight*' (the renderer's channel, which
  draws the current match with the `isearch' face and the others with
  `lazy-highlight' already), `query-replace-map' as a real keymap of
  ANSWER SYMBOLS, the four commands (M-% bound, C-M-%, replace-string
  and replace-regexp M-x-only). The whole loop is in a `dynamic-wind'
  (the C's unwind-protect) so C-g clears the highlight.
- **`schemacs/editor/indent.sld`** (NEW, the start of indent.c):
  `current-column' over `current-line-display-column' (disp-table's).
- **keyboard.sld**: `quoted-insert' (C-q) + `read-quoted-char' (octal
  input, radix parameter, first-C-g-is-code-7, later C-g quits,
  non-digit terminators pushed back raw) + `key-path->char-code' (the
  decode's inverse). They are HERE, not in simple.sld, for the import
  graph (simple is imported BY keyboard).
- **files.sld**: `insert-file-contents' (fileio.c's, visit/replace
  semantics - the visit clears the modified flag; find-file-noselect's
  inline reading was NOT refactored onto it yet), `insert-file'
  (C-x i), `find-file-read-only' (C-x C-r), `find-file-other-window'
  (C-x 4 f - a THREE-key key path, which keymap.sld handles without a
  submap), `find-alternate-file' (C-x C-v, the " **lose**" dance),
  `revert-buffer' + `revert-buffer--default' (M-x; the buffer-local
  `revert-buffer-function' is consulted, exactly Emacs's dispatch),
  `not-modified' (M-~), `files--message'.
- **buffer.sld**: `erase-buffer' (buffer.c's - the engine calls go
  direct, editfns cannot be imported here), `buffer-fill-column'
  accessors (default 70).
- **minibuffer.sld**: `set-fill-column' (C-x f; prompts, so it is here
  beside goto-line), the history record accessors are now EXPORTED
  (`make<history>' etc. - replace.sld owns its own
  `*query-replace-history*').
- **casefiddle.sld**: the string/char case functions `upcase',
  `downcase', `capitalize', `upcase-initials' (casefiddle.c's, over
  `casify-object') - `replace-match''s case transfer casifies with
  them.
- **paragraphs.sld**: `mark-paragraph' (M-h) with the extend branch
  (`*last-command*' is simple.sld's, not keyboard's).
- **buff-menu.sld**: the local `revert-buffer' command is GONE. `g'
  binds the global `revert-buffer', and `list-buffers-noselect'
  installs the buffer-local `revert-buffer-function' closure (refresh
  + redraw) - Emacs's shape (special-mode-map inherits `g' to the
  global command; tabulated-list-mode sets the buffer-local function).
- **simple.sld**: `read-only-mode' now at C-x C-q (files.el:9330;
  C-x q is kbd-macro-query's, not ported).
- Wiring: build.scm, Makefile, both platform files (`(only (schemacs
  editor replace))' for the M-% bindings), tools/run-suites.py gained
  search-tests.scm and replace-tests.scm.

## Tests

- search-tests.scm: 37 (translation, match data conventions - one-based
  in buffers, zero-based in strings - case transfer, both replace-match
  paths, the error strings).
- replace-tests.scm: 14 (the answer map, the caret descr, the automatic
  path: counts, case, delimited, region limits). The QUERY loop is
  pty-tested; it draws.
- ncurses-editor-tests.scm: 229 - the read-only-mode tests press the
  NEW C-x C-q chord.
- pty-check.py: 11 new checks (query-replace, query-replace-quit,
  replace-string, quoted-insert, insert-file, find-file-read-only,
  find-alternate-file, revert-buffer, not-modified, set-fill-column),
  each seen failing before its fix.

## Bugs this pass fixed or hit

- **Elisp-nil vs Scheme-'() truthiness, again**: query-replace's
  `(defaults ...)' test fired on the EMPTY list and `(caar '())' died
  - `'()' is true in Scheme. Now `(pair? defaults)' everywhere a C test
  would read nil.
- **`format' is Guile's**: `~a', not `%s'/`%d' - a `%s' prints itself.
  The compile warnings caught mine.
- **`string' the constructor vs `string' the parameter**: search.sld's
  replace-match took STRING as a parameter and the substitution walks
  called `(string c)' - the PARAMETER, called as a procedure. The walks
  build strings with `make-string' now.
- **define-command vs define**: find-alternate-file was written as a
  plain define, so the key dispatch fed it the RAW PREFIX as its
  filename ("Wrong number of arguments" in the pty, silently wrong
  otherwise). Registered commands are what the dispatcher's
  interactive machinery finds.
- **push-mark's three optional args**: insert-file-1 gave it
  `(location #t #t)' - the #t NOMSG suppressed "Mark set". The C's call
  is one argument.
- **zerop** is Elisp; `(= arg 0)` here.
- The REUSE extension of `match-data' splices with `list-copy' (the
  first version's `last-pair' trick shared structure).

## Still open in these groups

- `fill-paragraph' (M-q) and the whole of fill.el - deferred, as Chris
  decided; needs its own pass.
- The regexp variants' remaining surface: `map-query-replace-regexp',
  `read-regexp' (the C-y/M-s suggestion machinery),
  `keep-lines'/`flush-lines'/`occur' - the whole second half of
  replace.el.
- `query-replace-descr' shows control chars as caret TEXT, not the
  display-property form; the from-to separator history entry is out.
- find-file-noselect still reads files inline; folding it onto
  `insert-file-contents' is a small refactor left undone.

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
- **A stale `.go` file is read by `--no-auto-compile` runs even when no
  record changed**, and it makes bisecting meaningless: with a stale
  `xdisp.sld.go` in the cache, three successive "reverts" all tested the
  same old binary, three different conclusions were drawn from it, and a
  "fix" looked like it did nothing. The `--no-auto-compile` flag stops
  *compiling*; loading an existing `.go` is ordinary behaviour. After any
  run that leaves a `.go` behind (anything that ran without the flag),
  `rm -rf ~/.cache/guile/ccache` before trusting a test result — or check
  for the "newer than compiled" warning, which an import under
  `--no-auto-compile` prints.
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

Optional parameters are not spelled `&optional' - that is not Guile syntax
and it reads as two required parameters, so the command takes the wrong
number of arguments from M-x ("Wrong number of arguments to #<procedure
...>") or, when the command loop swallows it, quietly does nothing. The
tree's convention is the pattern `split-window-below' uses: fixed
parameters whose values the interactive *expression* supplies -
`(define-command (scroll-left arg set-minimum) ... (interactive (list
(current-prefix-arg) (uarg->integer 1 (current-prefix-arg)))) ...)' - which
is also how an interactive spec of several codes (`^P\np' in window.c) is
reproduced: one list element per code.

An interactive expression evaluates in the command's *defining* module, so
every name it uses must be imported there: `toggle-truncate-lines' in
simple.sld was unbound on `current-prefix-arg' because simple.sld's
`(schemacs editor command)' import did not have it - the missing-import
class again, swallowed by the command loop into a key that does nothing.

Horizontal scrolling landed 2026-10-01 (`hscroll', auto-hscroll-mode,
scroll-left/scroll-right); GTK-PLAN.md section 11 has the details and the
`emacs -nw' measurements the port was checked against.

## The clipboard work (2026-10-01)

The kill ring reaches the system clipboard on both frontends. Most of the
machinery was already in the tree as uncommitted work when this pass began
(`select.sld`, the `dispnew' selection generics, the GtkClipboard FFI in
`pgtk.sld', the `interprogram-cut/paste-function' hooks in simple.sld); this
pass fixed it, wired the build, and added the terminal half.

- `select.sld' (a full port of select.el) is in build.scm and the Makefile now;
  `x-get-clipboard' is exported.
- `pgtk.sld' loads again - the FFI section used `int'/`void' ((system foreign))
  and `assq-ref' ((guile)) without importing them. `gtk_clipboard_wait_for_text'
  returns a NULL pointer for an empty clipboard, which the FFI wraps as a *true*
  pointer - ask `null-pointer?', not `text'; and `pointer->string''s second
  argument is the LENGTH (-1 for "up to the NUL"), the encoding its third.
  UTF-8 is pinned on both directions, and the `gchar *' is `g_free'd.
- simple.sld's `current-kill' now signals "Kill ring is empty" (the `(or ring
  (error ...))` never fired - `'()' is true in Scheme), and `kill-new'/
  `kill-append' take Elisp's `(car nil)'-is-nil reading of an empty ring.
- keyboard.sld ports command_loop_1's else-branch (keyboard.c:1615): with the
  mark still active after a command and `select-active-regions' on, PRIMARY is
  set to the region after *every* command, `selection-inhibit-update-commands'
  honoured, `saved-region-selection' cleared (keyboard.c:1647).
- The tty half is a port of xterm.el 31 (which DOES have OSC 52 - see
  `xterm--selection-char', the tty `gui-backend-*' methods, `xterm-max-cut-length',
  and the version-203 activation): logic in `xterm.sld' (`xterm--tty-set-selection',
  `xterm--tty-get-selection', hand-rolled base64 - data-encoding.sld's
  `encode-data' is a TODO stub), the two `<tty-display>' methods in `term.sld',
  `display-selections-supported?' in dispnew.sld, and the tty branch of
  `display-selections-p' in frame.sld with `tty-select-active-regions'. Set is
  on for an xterm >= 203; the read stays opt-in (`xterm--get-selection'), as
  xterm.el keeps it.
- tools/syntax-check.scm re-execs itself with --r7rs: Guile's default reader
  misreads `|sym;with;semis|' (select.sld's `text/plain;charset=utf-8' target),
  which made a clean file report a phantom unbalanced paren.
- Tests: select-tests.scm grew the empty-ring cases and the OSC 52 write-path
  cases (32 tests); pty-check.py grew `osc52' (C-w emits `\e]52;c;<base64>\a'
  and no read query). Verified by hand on the desktop: `gui-set-selection' reaches
  `wl-paste', `wl-copy' is read back through `gui-get-selection', non-ASCII both
  ways. Deferred as in Emacs: `save-interprogram-paste-before-kill',
  `kill-transform-function', `yank-from-kill-ring', the screen/DCS OSC 52 wrapper.

## BASIC-FUNC.md's four commands (2026-10-02)

`what-cursor-position' (C-x =), `recenter' (C-l), `goto-line' (M-g g, M-g
M-g) and `write-file' (C-x C-w) are in, with the Emacs code they port from
named on each. The four pty checks (what-cursor, goto-line, write-file,
recenter) cover them.

- `what-cursor-position' is simple.sld's, `single-key-description' the
  keymap.sld one it needs (keymap.c's `push_key_description': TAB, RET, ESC,
  DEL, SPC, C-letters).
- `recenter' is frame.sld's - window.c is that file's in this tree - and
  sets the window's top line to the one ARG lines above point's, exactly
  the C's arithmetic with the margin clip.
- `write-file' and `set-visited-file-name' are files.sld's, with
  `directory-name-p' and `file-writable-p' (fileio.c's) beside them; the
  overwrite confirm is `y-or-n-p'. `read-file-name' takes Emacs's optional
  DEFAULT now, which write-file uses for a buffer that visits nothing.
- `goto-line' is in **minibuffer.sld**, not simple.sld, with
  `goto-line-read-args' and `read-number' (subr.el's, beside
  `read-char-from-minibuffer' and `minibuffer-default-prompt-format', which
  are minibuffer.el's). The reason is the import graph: simple.sld is below
  the minibuffer - minibuffer imports simple for `self-insert-command', and
  the command loop imports both - so a command that prompts cannot live
  there, which is the same wall `yank-from-kill-ring' waits behind.
  simple.sld's read-args-and-prompt cluster moves there the day the
  layering is fixed.

Gotchas from the work: Guile's `format' takes the DESTINATION first -
`(format #f "...")' for a string, and the frame as destination is the
"classic" mistake three of these commands made; `read-number''s cons
default drops its nil entries the way Emacs's `delq nil' does; and the
find-file prompt prefill is real minibuffer content, which is why the
prompting pty checks type `C-a C-k' before an absolute path.

## save-excursion, the position primitives, and BASIC-FUNC's groups 6-9 (2026-10-02)

`save-excursion' was missing and its absence was the reason ports of
.el functions came out as hand-rolled cursor save/restore dances. It is
now `editfns.sld''s - a macro over `dynamic-wind', holding a POINT
MARKER like the C's `save_excursion_save' (so it follows edits inside
the body), restoring the buffer and point in the wind's after thunk.
Beside it, the editfns.c primitives came over under their own names:
`point', `point-min', `point-max', `goto-char', `bobp', `eobp', `bolp',
`eolp', `char-after', `char-before', `following-char', `preceding-char',
`line-beginning-position', `line-end-position', `buffer-substring',
`buffer-size', `buffer-string', `insert', `delete-and-extract-region',
`point-marker', `barf-if-buffer-read-only', `forward-line' (public -
paragraphs.sld's walks call it), `search-forward' and `search-backward'
(with COUNT, and the fold-override `zap-to-char' needs).

A position convention is now settled: the Emacs-named layer answers
ONE-based positions ((point), point-min/max, region-beginning/end,
search-forward/backward) and converts at the engine boundary
(kill-region's -1s, casify-region's -1s, deactivate-mark's and the
command loop's PRIMARY copies). `delete-region' is **no longer** an
exception - see "`delete-region' is one-based, and AGENTS.md said otherwise"
further down, which dates from the 2026-10-05 conversion. The sentence that
used to stand here said its callers pass engine positions; it was true when
written and two callers still do, harmlessly.

`casefiddle.sld' (NEW, mirrors casefiddle.c): `casify-region' and
`casify-word' over a per-character walk - `word-char?' is the syntax
table's stand-in - with `upcase-region', `downcase-region' (C-x C-u,
C-x C-l) and `upcase-word', `downcase-word', `capitalize-word'
(M-u/M-l/M-c). `paragraphs.sld' (NEW, mirrors textmodes/paragraphs.el):
`forward-paragraph', `backward-paragraph', `kill-paragraph' (M-k),
`backward-kill-paragraph' (M-C-k) - the walks test the DEFAULT
`paragraph-start'/`paragraph-separate' blank-line patterns directly,
there being no regexp engine; when one comes, the walks become that
walk. Both are wired into both platforms' import lists (the
`define-key'-at-load-time rule). `zap-to-char' (M-z) is in
minibuffer.sld - it prompts, and simple.sld is below that library.

Group 9 (`transpose-chars' C-t, `transpose-words' M-t) is simple.sld's,
over `%transpose-subr'/%transpose-subr-1 - whose edit sequence is
Emacs's insert-before-markers/extract/reinsert, with the boundary
marker tracked by arithmetic (+len2 on the first insert, -len1 on the
delete). Group 6's commands (`open-line' C-o, `delete-indentation'/M-^,
`just-one-space' M-SPC with Emacs's skipped-spaces-come-off-N subtlety,
`delete-blank-lines' C-x C-o, `delete-horizontal-space' M-\, and mg's
`delete-leading-space'/`delete-trailing-space' spellings) are there
too, `fixup-whitespace' and the blank-line walks through
`save-excursion'. M-z was `read-only-mode''s key in a stale test's
expectation - the test moved to M-Z.

The audit that found the gap (Emacs defuns with save-excursion vs
ours): 82 in the mirrored files, 75 not yet ported (they get it for
free when they come), 6 ported - `fixup-whitespace' now uses it,
`kill-region'/`next-line' turned out to be scan artifacts, and
`split-window-below'/`minibuffer-completion-help' have named
deviations (the thin split port; the field-end computation absent).

## The shape refactors (2026-10-02, after the audit)

The functions whose shapes had departed from Emacs's because primitives
were missing were reworked onto them:

- `skip-chars-forward' and `skip-chars-backward' are ported -
  `syntax.sld' (NEW, mirrors syntax.c), whose BOUND argument is a
  one-based position like every other answer of the Emacs-named layer.
  simple.sld's private `%skip-chars-*' walks are gone;
  `delete-space--internal' and `just-one-space' are now the C's shape -
  the skips move point, and the deletion runs between where they leave
  it.
- `transpose-subr-1' uses `delete-and-extract-region' (which is also
  fixed - it mixed a one-based `buffer-substring' with an engine-based
  `delete-region').
- `delete-indentation''s join loop is Emacs's shape: point to the line
  beginning in the condition (`beginning-of-line' standing for the C's
  `(forward-line 0)'), `preceding-char' for the newline question,
  `(delete-char -1)' for the break.
- `what-cursor-position' is the C's let* - `(point)', `(buffer-size)',
  `(following-char)', the EOB question `(= pos (point-max))'.
- `forward-paragraph'/`backward-paragraph' use the public `forward-line'
  (with its not-moved answer) instead of private duplicates.

The engine cursor bug found under this work: `%text-editor-merge-
previous-line!' left point at the END of the merged line instead of the
join - DEL at a line start threw point to the end of the buffer's
remainder. Fixed in engine.sld (the merge now puts the cursor at the
former end of the previous line, which its own docstring already
claimed). `syntax.sld' is in build.scm and the Makefile; it carries no
bindings, so the platforms need no import for it.
## The current-buffer leak in the minibuffer, and write-file (2026-10-02)

`write-file`'s pty check failed with the file holding the *minibuffer's*
text: `save-buffer` had run on the prompt's echo-area editor. The chain:
while a prompt is read, `(current-buffer)` is the echo-area editor (the
`*echo-area-buffer*' fallback); the new `save-excursion`-using `kill-line`
- `C-k` in the prompt kills the prefill - restores the buffer it saved,
and its restore is a `set-buffer`, which *pins* that echo editor in
`*current-buffer*' permanently. After the prompt, every command acted on
the dead editor: `write-file' then read its default off a buffer named
"Untitled" (the engine's default buffer name) and saved *it* to the file
the user named.

The departure from Emacs is one missing guard: `read_minibuf'
(minibuf.c:675) does `record_unwind_current_buffer' - the current buffer
is restored when the read is over, however the prompt's commands left it.
The port now does the same: `read-minibuffer-1' parameterizes
`(*current-buffer* #f)' around the recursive edit, so the unwind restores
the asker's state whatever the prompt's commands pinned. `save-excursion'
itself is untouched - Emacs's restore is `Fset_buffer' too; the guard
belongs where Emacs put it.

Found by tracing `read-minibuffer-1' and `write-file''s interactive on a
pty run: `TRACE-WF curbuf="Untitled"` after a find-file that had opened
the right buffer. The doubled write-file prompt prefill (`/tmp/tmp/')
that led here was a probe artifact - the drive had omitted the `C-a C-k'
before the path, so find-file visited a doubled directory - not a bug.

## The compile warnings (2026-10-02)

- `pgtk-names.scm' imported `(gi)' wholesale, which re-exports
  `connect'/`equal?'/`format'/`write'/`quit'/`shutdown' over the core
  bindings - six warnings at every GTK start. It still needs `(gi)'
  *loaded* (it initializes the girepository runtime; without it
  `typelib->module' segfaults), so `(gi)' stays but the six names are
  `#:hide'd. `pgtk.sld''s own `(gi)' import keeps everything but
  `equal?' - the `equal?' clash is gone - and why `connect' and `make'
  have to stay in it is in "What cannot be fixed here, and why", below.
- `subr.sld' held the whole `kbd' block TWICE - an older, incomplete
  copy (no `char-numeric?' digit skip, which was the "possibly unbound
  char-numeric?" warning) above the real one; the real one shadowed
  everything. The first copy is gone.
- simple.sld: what-cursor-position's `Hscroll=~a' message called
  `format' without a destination (Guile's takes it first) - the suffix
  never formatted; `delete-indentation''s join loop used Elisp's `while'
  (unbound - `M-^' with no region did nothing) and `forward-line 0''s
  two roles are spelled out now (move = `beginning-of-line', and 0 is
  true in Elisp, false here); `%transpose-subr''s arg-zero case had `ed'
  bound in the same `let' that used it, and is now Emacs's shape -
  `save-excursion' with `exchange-point-and-mark' after it, outside the
  excursion. The splice of that case went wrong three times; the method
  that finally worked was rebuilding the WHOLE `%transpose-subr' define
  fresh in a file, verifying its `cond' had its three clauses with the
  reader (`guile -c '(read ...)'` and counting), then splicing the whole
  block - and even then the reader's ok is not the whole story: the
  `cond' closed early once with the file still balanced, which the
  compiler caught as "bad use of 'else'".
- `delete-indentation' had NEVER worked - the unbound `while' swallowed
  every call - so the rewrite exposed three layers under it, each read
  off a live editor through the REPL: `line-beginning-position'/
  `line-end-position' took an optional explicitly given as nil (Elisp's
  `(and arg 2)') as a real count, where Emacs's nil means absent - both
  now read nil as 0; the loop's `beginning-of-line' answers zero values
  where the condition needs one (Elisp's `(forward-line 0)' answers 0,
  true there, so the condition supplies the value); and
  `(= (preceding-char) ?\n)' is `char=?' here - chars are not numbers,
  and `preceding-char' answers #f at BOB where Elisp answers 0, which
  the condition guards with the same false answer. M-^ with and without
  a prefix arg joins "aaa\nbbb" to "aaa bbb" as Emacs's does.
- simple.sld's export list dropped `kill-line-chunk' and
  `kill-line-command', neither defined nor used anywhere.

## What cannot be fixed here, and why (2026-10-02)

Three classes of warning remain after the pass above, each measured
rather than assumed:

1. **`X - non-Object interface wants signals'** for `Component',
   `Selection', `Editable', `Text', `Hypertext', `Value' and `Table'.
   Those are GTK 3's AT-SPI accessibility interfaces, loaded because
   `typelib->module' brings Gtk's whole dependency closure (Gdk, Pango,
   GLib, Gio, Atk), not because anything here asks for them. The warning
   is printed by guile-gi's *compiled C* - the string exists only in
   `/usr/lib/guile/3.0/extensions/libguile-gi.so.6.0.1', nowhere in
   `/usr/share/guile/site/3.0/gi/' - while it builds generics for each
   interface it finds: interfaces that are not GObjects cannot have
   signal generics, so it skips them, warns, and moves on. Nothing in
   this tree can reach it - it is not a Guile warning, so no import form
   or variable silences it, and the skip is the *correct* behaviour
   anyway. Fixing it means a one-line patch to guile-gi's C (suppress
   the notice for non-Object interfaces) and a local rebuild of the
   package. Harmless here: nothing connects to an ATK interface.

2. **`connect' imported from both (gi) and (schemacs editor
   pgtk-names)' / `make' imported from both (oop goops) and (gi)'.**
   These two are the duplicate-binding `merge-generics' handler doing
   its job: guile-gi's handler intercepts exactly this kind of
   collision, merges the two generics, and the merged one is the only
   `connect' that survives a real `(connect <GtkWindow> <signal>
   handler)' call. Measured, not guessed: importing only `(gi)''s
   connect, or only the typelib surface's, or excepting either from the
   import, all end the same way - `gig_object.c:421' calls
   `g_signal_lookup' on a NULL self and the editor segfaults at the
   first connect; excepting `make' as well killed the editor at startup
   in a clean isolated run (cold cache, nothing else running). The cure
   is outside this tree: guile-gi would have to register one shared
   generic in both modules so the duplicate never arises, or Guile would
   need an import form that says "expect this duplicate, handle it,
   don't warn". Both warnings are also *cold-cache only*: a warm start
   of the same code prints neither, so what `seg' shows depends on
   whether the modules were compiled.

3. **`non-literal format string'** in minibuffer.sld (three sites). They
   are all `(format #f minibuffer-default-prompt-format ...)'. The
   warning is the compiler saying it cannot check the format string
   against its arguments at compile time because it is not a literal -
   and it must not be one: it is ported from Emacs's
   `minibuffer-default-prompt-format' defcustom (`" (default %s)"',
   minibuffer.el), which the user is meant to customize, and
   `format-prompt' fills it at run time. Making it a literal would
   compile cleanly and break the customizability, which is the feature
   being ported. Same class as C's `printf(non-literal)' notice.

So a warm-cache GTK start prints exactly the seven class-1 warnings and
nothing else; a cold-cache one adds the two class-2 warnings while the
modules compile; class 3 shows only under the compiler.

# Handoff — `sequence.sld` is gone (2026-10-05)

## What landed

`schemacs/sequence.sld` (603 lines, the original author's, untouched since
2026-09-25) is **deleted**. It was a portability shim: a ten-field
`<sequence-iface>` record whose fourteen hand-written tables re-spelled,
per element type, operations Guile already performs generically. Its
consumers — `gap-buffer.sld`, `editor/cdf.sld`, `editor/engine.sld`, and
`gap-buffer-tests.scm` — now call Guile directly.

`plans/ORIG.md` had concluded it "could shrink a lot but can't disappear",
because "there is no generic way to say *give me an empty u32vector of
length n*". **That was wrong.** `make-typed-array` is exactly that call, and
its type argument is exactly what `array-type` returns; the two round-trip
for every array type. `sequence.sld` disappears.

## The new leaf library, and why it must be a leaf

`schemacs/arrays.sld` (new, ~120 lines) holds the two primitives Guile does
not have, and **no growth policy** — a policy is a caller's business:

- `%array-copy-range!` — R7RS `copy!' order, any two array types,
  overlap-safe. This is `iface-sequence-copy!`, and it is the *only* part of
  the iface the gap buffer could not do with a plain Guile call.
- `%array-resize` — a new array of the same type with the old contents in
  its prefix; answers the *same object* when the length is unchanged, which
  `cdf-fill` tests with `eq?`.

Everything else is a plain Guile call at the call site.

It has to be a leaf because of the import graph, not for style:

```
        (schemacs arrays)          <- leaf (was (schemacs sequence))
          /            \
  gap-buffer.sld      cdf.sld
          \            /
     (schemacs editor engine)      <- imports both
               |
     (schemacs editor buffer)      <- imports engine
```

`buffer.sld` imports `engine`, `engine` imports `gap-buffer`, so a helper
`gap-buffer.sld` needs cannot live in either — it would be a cycle. Of the
Emacs files these operations belong to, `make_gap`/`make_gap_larger`/
`gap_left`/`gap_right` are **insdel.c** (this tree's `engine.sld`),
`enlarge_buffer_text` is **alloc.c**, and only the *shrink* policy
(`compact_buffer`) is **buffer.c**. None is `buffer.c`'s management half,
which is what `buffer.sld` mirrors.

## The two Guile facts this rests on (measured on 3.0.11, not assumed)

- `array-copy!` is `(_ _)` — **two arguments, whole arrays only** — and it
  is a *forward loop*: shifting right within one array corrupts it
  (`#u32(10 20 30 40 50)` → `#u32(10 10 10 10 50)`).
- `vector-copy!` **refuses every SRFI-4 vector**: *"Wrong type argument in
  position 1 (expecting mutable vector): #u32(...)"*. That, and only that,
  is why `gap-buffer.sld` carried two hand-rolled element-by-element loops
  under `cond-expand (guile ...)`. There is no `u32vector-copy!`, and
  `uniform-vector-copy` / `uniform-vector-copy!` **do not exist**.
  `(srfi srfi-63)` is not installed.

`%array-copy-range!` gets a *range* by asking `make-shared-array` for a view
of it, and gets the overlap right by **reversing both views** when the
destination is above the source: the same forward copy then moves the
elements in the opposite order, which is exactly memmove's backward case.
Verified for all eleven array types. `array-copy!` is also cross-type
(`vector` slice → `u32vector` slice works), so growth across types is free.

The `cond-expand (guile ...)` in `gap-buffer-move-cursor` is **gone**.

## The growth policy is Emacs's now (Chris's catch)

The tree had **two doublings** — `sequence.sld`'s `default-allocate-function`
and `gap-buffer.sld`'s `*gap-buffer-grow-size-function*`. Emacs does not
double anywhere. `gap-buffer.sld` now ports `make_gap` (`insdel.c:583`) and
`make_gap_larger` (`:467`):

```c
make_gap_larger (max (nbytes_added, (Z - BEG) / 64));
nbytes_added = min (nbytes_added + GAP_BYTES_DFL, ...);   /* 2000 */
```

and the call shape from `insert_1_both` (`:915`):
`if (GAP_SIZE < nbytes) make_gap (nbytes - GAP_SIZE);` — the argument is the
**shortfall**, guarded outside. So `gap-buffer-grow` is now that shape and
`*gap-buffer-grow-size-function*` is gone; `*gap-bytes-dfl*` (2000) and
`*gap-bytes-min*` (20) are ported from `buffer.h:205,210`. `compact_buffer`'s
shrink (`buffer.c:1857`) is ported as `gap-buffer-compact`, and **has no
caller yet** — in Emacs its caller is the garbage collector, and there is no
equivalent pass here.

`gap-buffer-allocate` stays **grow-only** (a smaller request is ignored),
which is its documented behaviour; shrinking is `gap-buffer-compact`'s.

**`gap-buffer-tests.scm` changed numbers, and that is expected.** It encoded
doubling (8→16, 4→8→16, `gap-buffer-allocate 50` → 64). Emacs's arithmetic on
stores this small is dominated by the `+2000`: 8→2009 and 4→2005. The
content, cursor and weight assertions were untouched — only the lengths moved.

## The the-numbers-mean-something-else caveat

Emacs's `GAP_BYTES_DFL` and `(Z - BEG) / 64` count **bytes**, because Emacs
has exactly one gap buffer and it holds bytes. Ours are typed element stores
— `u32vector` for the line editor, a `vector` of records for the lines — so
these count *elements*, which are four bytes each in the line editor. The
arithmetic is Emacs's; the unit is not, and that is a real departure.
`BUF_BYTES_MAX`, the C's other bound, has no analogue and is not applied.

## Per file

- **`gap-buffer.sld`** — the `iface` field is `seq-type` (an array-type
  symbol), `iface-*` are `array-*`, `seq-iface` is `seq-type`, and the two
  copy loops are one call to `%array-copy-range!`. New:
  `%gap-buffer-make-store` (the fill `make-typed-array` insists on, which
  `make-vector` let you omit), `%gap-buffer-realloc!` (one body for growing
  *and* shrinking, because where the segments go is decided by the new
  length and the weight, never the old), `%gap-grow-size`,
  `gap-buffer-compact`. Dead imports `get-sequence-iface` and
  `typeof-vector?` dropped (`typeof-vector?` is `array?` if ever wanted;
  note `(vector? (u32vector 1))` is `#f` while `array?` is `#t`).
  **`array-set!` takes the value *before* the index** — several call sites
  had to flip.
- **`cdf.sld`** — `u64vector-sequence-iface` → `'u64`; `cdf-vector-iface`
  renamed `cdf-vector-seq-type` (nothing imported it). The CDF's doubling
  is kept but moved inline as `%cdf-allocate-size`/`%cdf-allocate`, marked
  **non-Emacs and transitional**: Emacs answers what the CDF answers with
  intervals, so there is no Emacs policy to copy. The `(max 1 len)` that
  makes `(new-cdf 0)` work is kept.
- **`engine.sld`** — `%line-editor-pre-freeze` returns `'vu8` / `'u16` /
  `'u32`; the `text-line` record's `iface` is `type` (`text-line-seq-type`),
  still `#f` for an empty line; `(get-sequence-iface string)` is
  `(array-type string)` = `'a`. Five dead imports dropped, and the dead
  `cdf-sequence-iface` define removed.
- **`build.scm` / `Makefile`** — `(schemacs arrays)` added.

## Bugs this work found

- **`engine.sld`'s `text-line` was broken and never noticed**: its
  `set-char!'` call omitted the index, passing two arguments to a
  three-argument setter, so it failed on *any* non-empty string. Nothing in
  the tree calls `text-line`, so it was exported and dead. Rewriting the
  call to `array-set!` forced the index in; it is correct now.
- **`get-sequence-iface` was broken on Guile**: it tested `bytevector?`
  before the SRFI-4 predicates, and in Guile `(bytevector? (u16vector 1 2))`
  is `#t` — so every typed vector got the *bytevector* iface, with lengths
  counted in bytes and elements read as bytes. It survived only because
  every caller passed a named iface. **The type-symbol replacement cannot
  have this bug**, which is a real correctness win rather than a tidy-up.
- Also found dead: `seq-min-max` (exported, never defined), `sequence-grow`
  (always errored — passed a length where a sequence is wanted),
  `line-editor-freeze` (the live path is `line-editor-freeze-part`).

## Known departure to name

The storage layer is now **Guile-only**: `make-typed-array` and `array-type`
are Guile extensions, not SRFI-63. The library it replaces existed to be
portable across Schemes — that is the price of the removal. The tree already
`cond-expand`s heavily for Guile, and the non-Guile Makefile targets
(chibi/gauche/gambit/chez/stklos) lose the editor core. Called out here so it
is a decision on the record, not a discovery later.

## Tests

All 23 suites in `tools/run-suites.py` pass (engine-tests 113, buffer-tests
28, ncurses-editor-tests 232, …). `gap-buffer-tests.scm` 23 (rewritten
numbers), `cdf-tests.scm` 8, `vbal-tests.scm` 14, and `tools/pty-check.py`
**53/53**. End-to-end through the engine: round-trips that exercise each
freeze width (`vu8`/`u16`/`u32` by code-point range), a 20,000-character
single line forcing repeated gap growth, and edits at line starts and ends.
No new compiler warnings.

## Step 2, still to do (Chris's plan)

Nuke the `text-line` vector for the Emacs shape — one byte gap buffer, no
line editor, no CDF. When that happens `gap-buffer.sld` dissolves into
`engine.sld` (its Emacs counterpart, `insdel.c`), `cdf.sld` and
`cdf-tests.scm` go with the CDF, and `%array-copy-range!`/`%array-resize`
stop being a library at all and become `engine.sld`'s own functions. Step 1
was deliberately shaped not to prejudge that.

Step 2 also gives `gap-buffer-compact` its caller, and is where the
element-versus-byte unit question above gets settled.

# Handoff — `buffer-text`, the storage class (2026-10-05)

## What landed

`schemacs/editor/buffer-text.sld` (new) plus
`schemacs/editor/buffer-text-tests.scm` (58 tests). Wired into `build.scm`,
`Makefile` and `tools/run-suites.py`. **Nothing uses it yet** — the editor
still runs on `gap-buffer.sld` + the line editor + the CDF. This is the
class the conversion will move onto.

It is **GNU Emacs's `struct buffer_text`** (`buffer.h:240`) as an object:
the text, the gap, and where the gap is. The layout is Emacs's exactly -

```
store index   0 ......gpt-base......gpt-base+gap-size......z-base+gap-size
contents      |  before  |    the gap    |       after        |
```

- `z` is a *position* and is `point-max`; the character count is
  `(- z base)`, the allocation `(+ (- z base) gap-size)`. `BUF_Z_ADDR`
  (`buffer.h:990`) is `beg + gap_size + z_byte - BEG_BYTE` — the store
  ends at `z + gap_size`, which is why the after-segment is copied to the
  end of the new store on a realloc and not to `z`.
- `%at` is `BYTE_POS_ADDR` (`buffer.h:1078`) without the bytes.
- `%move-gap!` is `move_gap_both` (`insdel.c:94`), with `gap_left` and
  `gap_right`'s two directions as one `%array-copy-range!` each.
- growth is `make_gap`/`make_gap_larger` (`insdel.c:583`, `:467`) — the
  same arithmetic `gap-buffer.sld` got in the previous pass, `+2000` and
  `/64`, no doubling.
- insert and delete need **no shift at all**: `%move-gap!` has already
  put the gap where the edit goes, so insert writes into the gap and
  delete absorbs characters into it by growing `gap_size`.

## The API

Positions are **1-based at the API and array indices inside**; `base` is
added or subtracted only at that edge. `new-buffer-text` takes `base`, and
the one construction site passes 1.

```scheme
new-buffer-text base [size]     buffer-text-type?    buffer-text-base
buffer-text-z                   buffer-text-length   buffer-text-allocation
buffer-text-gap-size            buffer-text-ref      buffer-text-set!
buffer-text-insert! pos str     buffer-text-delete! from to
buffer-text-substring from to   buffer-text-for-each  buffer-text-clear!
```

`insert!` takes a **string**, on purpose: a Scheme string is a sequence of
code points and it is what everything above deals in, so the element type
never leaks out of the class. `ref` answers a code point as an exact
integer, matching `FETCH_CHAR` and elisp, where a character *is* an
integer.

## Deliberate departures to record

1. **The class itself.** Emacs has no such object; it has a C struct of
   five fields reached through pointer macros (`BEG_ADDR`, `GPT`,
   `Z`, `GAP_SIZE`, `BUF_GPT_ADDR`, ...). This is the same five fields and
   the same arithmetic, named rather than smeared across macros. That is
   the *point* - the representation can later become tiered or chunked
   without anything above it changing.
2. **`base` is a field.** Emacs hard-codes `BEG = 1`. It is a convention,
   not a knob: two buffer-texts with different bases cannot exchange
   positions, and positions do travel (markers, `insert-buffer-substring`),
   so every instance must be built with the same base. There is a comment
   on the constructor saying so.
3. **`u32vector` of code points, not bytes.** Emacs's is `unsigned char *`
   with the 1-to-5-byte `utf-8-emacs` encoding. This is one element per
   character, which is what deletes the byte/char duality (see the earlier
   handoff). Positions are therefore characters, and `PT_BYTE` has no
   counterpart.
4. **`compact_buffer`'s shrink is not ported.** `gap-buffer.sld` has
   `gap-buffer-compact`; this class has no equivalent yet, because nothing
   calls it. It belongs here when something does.
5. **`BUF_BYTES_MAX`** has no analogue and is not applied.
6. `buffer-text-clear!` is `erase-buffer` (`buffer.c:2472`) but keeps the
   allocation, which is what `erase-buffer` does too.

## The job this sets up

Convert the editor onto it. Roughly, and in this order:

1. `<text-editor>`'s `lines` gap buffer, `line-ed` line editor and `cdf`
   become **one** `buffer-text`. The line editor, `load-current-line`, the
   write-back, the freeze machinery and `%line-editor-pre-freeze` all go;
   so do `cdf.sld`, `gap-buffer.sld` and their tests.
2. `point` becomes the buffer-text position, and the line/column
   arithmetic becomes index arithmetic over ports of `find_newline`
   (`search.c:675`), `line-beginning-position` (`editfns.c:700`) and
   `line-number-at-pos` (`fns.c:6688`) - Emacs scans for lines, it has no
   index, and neither will we.
3. The display layer (`disp-table.sld:200`, `xdisp.sld`) reads the line
   editor directly today and assumes a line is contiguous; it converts
   too, and it is the part most likely to break subtly.
4. Several test suites encode the old model and will need rewriting. They
   are the safety net for a rewrite this size.

`text-editor-char-count` is a hand-maintained counter that has corrupted
things three screens from its cause (see the warnings above). Once the
class owns the length it stops existing as a separate field - make
`buffer-text-length` the only answer.

# The engine onto `buffer-text` — done (branch `emacs-text-storage`, 2026-10-05)

**Every suite passes.** All 24 in `tools/run-suites.py`, with no failures in
any of them. The branch is still a branch because it has not been merged to
`main` and `tools/pty-check.py` had not finished when this was written.

## What landed

- `<text-editor-type>`: seven fields (`lines`, `count`, `line-ed`, `line-ch`,
  `moved`, `column`, `cdf`) collapse to two - `text` (a `buffer-text`) and
  `point` (a `buffer-text` position, one-based).
- The CDF, the line editor, the freeze machinery and the merge helpers are
  gone; a line break is a character, so joining two lines is deleting it.
  `cdf.sld`, `cdf-tests.scm`, `gap-buffer.sld` and `gap-buffer-tests.scm` are
  deleted. `(schemacs arrays)` stays: `buffer-text` gets
  `%array-copy-range!` and `%array-resize` from it.
- The line arithmetic is Emacs's own scans, ported under their Emacs names
  into `engine.sld`: `find-newline` (`search.c:675`),
  `scan-newline-from-point` (:986), `bol` (`editfns.c:665`), `eol` (:723),
  `find-before-next-newline` (`search.c:997`), `count-lines`
  (`xdisp.c:29892`).
- **The engine, and every caller above it, speaks Emacs's coordinates**:
  `point-min` is 1, `point-max` is one past the last character, line numbers
  count from 1, columns from 0. The interval/text-property layer too - a
  buffer's intervals are 1-based, a string's are zero-based, as Emacs's are.

## The conventions (Chris's call; he was right)

I first wrote that the engine's zero-based cursor must be preserved to avoid
touching ~100 call sites. That was wrong: **a zero-based position is itself a
departure from Emacs**, and the point of the work is to stop having
departures.

| | Emacs | was | now |
|---|---|---|---|
| character position | 1-based — `point` | 0-based | 1-based |
| line number | 1-based — `line-number-at-pos` (`fns.c:6688`) | 0-based | 1-based |
| column | 0-based — `current-column` (`indent.c:298`) | 0-based | 0-based |

## The departs that were found and fixed — every one a `0` or a `1`

The pattern is worth naming: **the port kept a ±1 at a seam**, and every seam
was in a different file, so the suites found them one at a time. Each is
listed with the commit that fixed it.

- `find-interval` rebound `position` to the *relative* position and then used
  it as the absolute one (intervals.sld).
- `adjust_intervals_for_deletion` passed the buffer position to
  `interval_deletion_adjustment` where the C passes `start - offset`
  (`BUF_BEG`). A deletion at `point-min` took one character off the run that
  should have gone and one off the run after it.
- `search.sld`: `looking-at` handed the regexp engine a **position** where it
  wanted an **offset**, so a pattern at point never matched - that is what
  Dired's indent is built on. `%re-search` answered `(+ 1 POSITION)` and
  translated the match data by `(+ base 1)`; `search-forward`/`-backward` had
  the same pair.
- `simple.sld`: `kill-region` subtracted one from BEG and END, so every kill
  started a character to the left.
- `simple.sld`: `isearch-find` referenced an unbound `count` - the caller
  sweep had renamed the binding to `max`, which also shadowed the core `max`.
  Every `isearch-find` call died.
- `dired.sld`, `font-lock.sld`: every property site on the interval seam had
  a `(- ... 1)`; at `point-min` one of them asked for position 0 and killed
  `dired-noselect` outright. `font-lock-extend-region-multiline` keeps its
  two: those `1-'s are Emacs's own.
- `window.sld`, `frame.sld`: a window's `top-line` was built as 0, so the
  display's row walk counted one row too many and drew the cursor a row low.
- `files.sld`: `add-line-break-at-end!` used the character *count* where
  `point-max` was wanted, so `require-final-newline` wrote `"a\nb"` for
  `"ab"`.
- `engine.sld`: `text-editor-to-string` was `text-dump-port`, which writes
  `\n` as the buffer's line break. Emacs's `buffer-string` is the raw text,
  and because `save-buffer` then ran `encode-line-breaks` over it, a CRLF
  file was written with `\r\r\n` - **a real bug on the old branch too**. The
  same pair of definitions (`text-load-port`/`text-dump-port`) was in the
  file twice; one copy remains.

## Method that worked, and one that did not

Reading the C is what landed every one of the above. The one that did not
work: a Python edit of the form
`open(p,'w').write(open(p).read().replace(...))` **truncates the file before
reading it** and wrote `replace.sld` out empty, which was then committed.
Read into a variable first, always.

Two tools that paid for themselves here and are worth reaching for first:

- `emacs -Q --batch --eval` for the expectation. Marker rules, `goto-line`
  past the end, `insert-file-contents`' undo recording, `kill-line`'s
  whitespace rule and the overlay front-advance rule were all settled by
  asking Emacs rather than by reasoning.
- printing stack frames with `(frame-procedure-name)` and
  `(frame-source)` only - never the values. The `<text-editor-type>` record
  printer crashes while Guile prints a backtrace, which hides the location;
  frames printed without their values do not.

## Still open

- `tools/pty-check.py` had not been run to completion when this was written.
- The renderer's line scans are O(n) per line: `find_newline`'s
  `region_cache` (search.c) is not ported, so a window redraw is quadratic in
  the buffer. It was quadratic before too, but by a different route.
- `get-free-disk-space` is not ported, so `dired--insert-disk-space` leaves
  the free-space `display` property off; the `total` line is still deleted as
  Emacs 31 deletes it.

# The window's start is a marker — done (2026-10-05)

## The departure, and what it cost

`<window>` kept its scroll position as `top-line` — a **buffer line
number**. GNU Emacs's window has no such field: `w->start` is a marker,
and the window's `top_line` is a *screen* coordinate ("The upper left
corner coordinates of this window, relative to upper left corner of frame
= 0, 0"). So we had taken Emacs's name for a screen row and used it for
something Emacs stores a position in.

Every use of it had to convert, and each conversion was a scan of the
buffer. Measured on a 20,001-line / 508,891-character file with point at
the end:

| | before | after |
|---|---|---|
| the 24 rows of one window | 487 ms | **0.2 ms** |
| 24 rows at the top of the same file | 0.4 ms | 0.4 ms |
| the mode line | 93 ms | 0.2 ms |
| `render!`, point at line 20001 | 296 ms | **19 ms** |
| `render!`, point at line 1 | 52 ms | 19 ms |
| **one keystroke** | **~440 ms** | **1-5 ms** |

The last two rows are the point: the redisplay no longer depends on where
you are in the buffer at all.

## What the record holds now

`w->start` as a marker, and everything Emacs stores beside it:

| field | Emacs | what it is |
|---|---|---|
| `start` | `w->start` | a marker: where the text being displayed begins |
| `start-at-line-beg` | `w->start_at_line_beg` | whether that was a line beginning |
| `end-pos` | `w->window_end_pos` | **`Z -`** the position of the last glyph — a distance from the *end* of the buffer, so an edit before it leaves it valid |
| `end-vpos` | `w->window_end_vpos` | the glyph matrix row of that last glyph |
| `end-valid` | `w->window_end_valid` | whether those two mean anything |
| `base-line-number`, `base-line-pos` | same | the `%l` cache: a line somewhere above the window, 0 = none, -1 = gave up |

`set-window-start!` sets `start` and `start-at-line-beg` together, as
every site in the C does. `set-window-buffer!` is `set_window_buffer`:
everything the window recorded about the old buffer - the end, the
cache, the hscroll - goes with it. The row walk begins at `window-start`
and steps forward, as the C's display iterator does, and records
`end-pos`/`end-vpos` as it draws instead of walking again for
`window-end`.

`%l` is the C's `'l'` case: `topline + count_lines (w->start, PT)`, with
`topline` from the base-line cache. The same count measured 20.3ms from
`point-min` and 0.033ms from the window's start - 620x - which is why
counting from the window matters and why the cache is worth having on
top of it.

## Deliberately not stored yet

Each of these has a reader in the C that this tree has no counterpart
for, so adding the field would be state nothing consults:

- **`b->last_window_start`** (`window.c:2521`): the start a buffer had in
  the last window disconnected from it. It is a buffer-local slot and
  `frame.sld`, where the record lives, is below the library that owns the
  buffer's slots. It would also have no effect - `scroll-to-cursor!`
  recomputes a window's start from its point on every redisplay, where
  the C's `w->start` survives until redisplay decides otherwise.
- **`w->force_start`, `w->optional_new_start`**: read by
  `redisplay_window`'s start decision. `scroll-to-cursor!` is this tree's
  stand-in for that decision and does not consult them.
- **`w->column_number_displayed`**: read by `mode_line_update_needed` and
  `redisplay_internal` to decide whether the mode line needs redrawing.
  This renderer redraws unconditionally.

## Deviations introduced by this work

- `set_window_buffer` writes `start_at_line_beg = false` and lets
  redisplay recompute it; `set-window-buffer!` has `set-window-start!`
  compute it from the text at once. Same value, arrived at earlier.
- `%l`'s give-up answer is `"??"`; the C pads it to the construct's
  field width first.
- `next-line`, `previous-line`, `scroll-up-command` and
  `scroll-down-command` are *line* arithmetic, where Emacs uses
  `vmotion` (indent.c) and so measures screen lines - they agree except
  on a wrapped line. They were line arithmetic before; they are now
  position-driven line arithmetic, which is what took next-line from
  89ms a keystroke to 5ms.

## Hazard worth knowing

`text-editor-ref` is `char-after` and answers a **character**, not a code
point, where `buffer-text-ref` answers an integer. Comparing its answer
with `=` against `#x0a` crashes the editor with `In procedure =: Wrong
type argument in position 1: #\newline`, several frames from the cause.
Use `char=?` and `#\newline`.

## Still open after this

- `find_newline`'s `region_cache` was not ported at the time of writing;
  it is now - see the next section.

# The line-break cache — done (2026-10-05)

## What landed

`schemacs/editor/region-cache.sld` is a port of `region-cache.c`, and
`find-newline` consults it, as `find_newline` does. `region-cache.h`
says what it is for: "some applications, like gene editing, make use of
very long lines --- on the order of tens of kilobytes", where scanning
to the next line break costs tens of thousands of characters *every*
time. The cache notes a stretch it has searched and found free of line
breaks, and the next search steps over it whole.

The buffer gained `newline-cache` - GNU Emacs's `buf->newline_cache` -
made lazily the first time a search wants it (`search.c:640`), so a
buffer whose lines are never searched never pays for one.

## The bug that made it look useless

The first measurement said the cache bought nothing: 225ms cold, 211ms
warm. Two things were wrong, and both are worth knowing:

1. **Nothing ever created the cache.** The field defaults to false and
   `find-newline` used `(or (%text-editor-newline-cache ed) ...)` only
   after I added the lazy creation the C does at `search.c:640`. Until
   then every lookup answered "no cache" and the whole port was dead
   code. A cache that is never populated is indistinguishable from one
   that never helps.

2. **`%line-end` did not go through `find-newline` at all.** It was a
   private character-at-a-time loop - a hand-rolled duplicate of a scan
   Emacs already has - so the most-called line scan in the engine
   bypassed the cache entirely. It is `(find-before-next-newline ed
   from 1)` now, which is `eol`'s own forward half.

After both, on 4 MB of 20,000-character lines:

| | ms |
|---|---|
| first pass over 200 long lines | 727 |
| the same pass again | **2.8** |
| a single `eol` cold / warm | 3.96 / **0.026** |
| a single `bol` cold / warm | 1.49 / **0.012** |

The hand-rolled loop this replaced cost 225ms for the first pass, so
**the cold pass is about 3x slower and every pass after it is 80-260x
faster.** That is the trade Emacs made too, and the redisplay repeats
these scans many times per redraw, so the warm case is the one that is
lived in.

## Invalidation

`text-editor-invalidate-caches!` is `invalidate_buffer_caches`
(`insdel.c:2206`), which the C calls from `prepare_to_modify_buffer`
before every change. It is called from the three writers in
`engine.sld` - `text-editor-force-insert-char` and the two delete
primitives. `erase-buffer` goes through `text-editor-delete-from-cursor`,
so it is covered without a call of its own.

The cache is told in the **HEAD/TAIL form** - "this many characters
unchanged at the beginning, this many at the end" - and not with
positions, because an insertion or a deletion moves everything after it
and that form reads the same before and after the change. For an
insertion at POINT the tail is `Z - POINT`, the same count either side.

Nothing is *repaired* at invalidation time; it only records that the
region is now unknown, and `revalidate_region_cache` cleans up in one go
the next time the cache is read. That is why the cost of an edit does
not depend on how much the cache knows.

## Departures

- The C reaches the buffer through `struct buffer *` and the `BEG`/`Z`
  macros; `region-cache.sld` sits under the engine and cannot see a
  `<text-editor-type>`, so the caller passes the two endpoints. A
  boundary is a pair and the array is a Scheme vector; the gap
  arithmetic and the relative-position scheme are the C's.
- `xpalloc`'s growth - "about 50%", `n = n0 + n0 / 2`, raised to what
  the caller needs - is `%grow-boundaries!`. No doubling.
- The C counts the line breaks immediately following a known run before
  consulting the cache again (`search.c:733-746`). This port consults
  every time. The answers are identical; only the number of
  consultations differs.
- `pp_cache` (the `ENABLE_CHECKING` pretty-printer), the
  `width_run_cache` and the `bidi_paragraph_cache` are not ported.
  Nothing here asks for the last two.

## Hazard found while porting it

`%insert-cache-boundary!` must write the new boundary at the **raw**
array index once `%move-cache-gap!` has put the gap there, as the C's
`c->boundaries[i]` does. Reading it back through the before/after-gap
arithmetic reads one slot past the end of the array - this failed with
`vector-set!: Argument 2 out of range: 40`, which says nothing about
which of the two branches is wrong.

## The `%l' cache's freshness rule was missing — found 2026-10-06

Found while surveying how faithful the engine is, not by a test:
`mode-line-line-number` had the right fields, the right `topline +
nlines` expression and the right refresh heuristic, and was missing the
one-line rule that says when the cache may be believed at all:

```c
#define BASE_LINE_NUMBER_VALID_P(w)                      \
   (eassert (current_buffer == XBUFFER ((w)->contents)), \
    !current_buffer->clip_changed                        \
    && BEG_UNCHANGED >= (w)->base_line_pos)
```

`w->base_line_pos` is a position and `BEG_UNCHANGED` counts characters
from the beginning of the buffer, so the test says "nothing before the
line I remember has changed" - which is the only thing that makes a
remembered *line number* still true, since a line number counts from
`point-min`.

Measured before the fix, over 400 states built from random edits with a
scrolled window: **160 wrong**, the mode line quietly showing the wrong
line. After it: **0**. `ncurses-editor-tests.scm` has the case.

The fix needed `beg_unchanged`, which is a `struct buffer_text` field
(`buffer.h:149`) that had never been ported - so the missing rule and the
missing field were the same omission. It is shrunk on every modification
to `change-position - BEG` (`insdel.c:1608`) and set to "everything" when
the cache is written, where the C sets it once per redisplay
(`xdisp.c:22732`); the `%l` cache is its only reader here. Emacs keeps
`end_unchanged` beside it and its readers (`window_outdated',
`redisplay_internal`) are not ported, so it is not carried.

**The lesson worth keeping**: a port can have Emacs's shape and still be
wrong, because the shape does not carry the invariants. This one was
invisible to reading and to every existing test; only measuring it
against a from-scratch count found it. `set-window-start!' computing
`start_at_line_beg` rather than writing `false` is the same kind of rule.

## modiff: `buffer-modified-p` is a comparison, not a flag — 2026-10-06

`text-editor-modified?` was a boolean the setters wrote. In Emacs it is
**derived**: `buffer-modified-p` is `BUF_SAVE_MODIFF (buf) < BUF_MODIFF
(buf)`, and `MODIFF` is a counter on `struct buffer_text` raised by
`modiff_incr` on every change.

Ported: `modiff` and `chars_modiff` on the buffer-text (both starting at
1, as a fresh buffer reports a tick of 1), `SAVE_MODIFF` on the editor,
`text-editor-modiff` / `text-editor-chars-modiff` (Emacs's
`buffer-modified-tick` and `buffer-chars-modified-tick`), and the C's
`set-buffer-modified-p` arithmetic - including the trick that marking a
buffer modified *raises* `MODIFF` when `SAVE_MODIFF` has caught up, which
is how "modified" is said of a buffer whose text never changed.

Checked against a real Emacs rather than reasoned about. Seven steps,
`emacs -Q --batch`:

| | tick | chars | modified |
|---|---|---|---|
| new buffer | 1 | 1 | nil |
| insert "a" | 2 | 2 | t |
| insert "b" | 3 | 3 | t |
| `set-buffer-modified-p nil` | 3 | 3 | nil |
| `set-buffer-modified-p t` | 4 | 3 | t |
| `put-text-property` | 5 | 3 | t |
| insert 10 chars | **9** | 9 | t |

Ours matches every row. The last is the point of `modiff_incr`: ten
characters raise the counter by four, not ten - the rise is
`len == 0 ? 1 : elogb (len) + 1`, logarithmic in the size of the change.
And `put-text-property` raises `MODIFF` without touching `CHARS_MODIFF`,
which is why the two counters exist apart.

### Two orderings that had to be right, and one silent bug

1. **The bump is per operation, not per character.** Our string insert
   goes character by character through `force-insert-char`, so bumping
   there gave ten rises for ten characters and a tick of 15 where Emacs
   gives 9. The C's `insert_from_string_1` does one
   `modiff_incr (&MODIFF, nchars)` for the whole string. The bump moved
   up to `text-editor-insert`, sized by `(- end beg)`, and the same for
   the delete path.

2. **The bump comes *after* the first-change mark.** `record_insert` runs
   before `modiff_incr` (`insdel.c:926-928`), and `record_insert` is what
   asks "is this the first change since the save?" - so `note-change!`
   must run while the counter still says unmodified. With the bump first,
   the `(t . TOKEN)` undo entry was never recorded and seven engine tests
   failed.

3. **A silent `replace` again.** One of the edits to `textprop.sld`'s
   import list did not match (wrong leading whitespace) and did nothing,
   so `text-editor-note-property-change!` was unbound at run time with
   no load-time error - the missing-import class, twice in one session.
   Assert on the match before replacing.

## Recentring: `scroll-to-cursor!` put point at the top where Emacs centres — 2026-10-06

Chris, from using the editor: "`C-v C-v C-v` in emacs and schemacs is the
same, cursor on first line. But if I then do `C-p` up one line, emacs
pages up half a page visually, while moving cursor up one line. schemacs
goes up one line only."

He was right. `scroll-to-cursor!` had, for point above the window:

```scheme
(set-window-start! window cursor-start)   ; point's line becomes the top
```

GNU Emacs does not do that. `redisplay_window`'s `recenter:` label
(`xdisp.c:21150`) seats the display iterator on point with
`it.current_y = it.last_visible_y`, and then

```c
  if (!MINI_WINDOW_P (w)
      && (scroll_conservatively > SCROLL_LIMIT || NUMBERP (aggressive)))
    { ...the conservative/aggressive arithmetic... }
  else
    /* Set the window start half the height of the window backward
       from point.  */
    centering_position = window_box_height (w) / 2;      /* :21197 */
```

**The `else` is the whole of the default behaviour.** The branch above it
is taken only when `scroll-conservatively` is over 100 or
`scroll-*-aggressively` is a number, and the defaults are 0 and nil. So
whenever point moves off the screen, Emacs puts the window start half a
window's height *backward* from point - point lands in the middle, which
is the "half a page" Chris saw.

The walk is `move_it_vertically_backward (&it, centering_position)`,
which turns the distance into lines with

```c
  nlines = max (1, dy / default_line_pixel_height (it->w));
```

and then walks back that many *visible line* starts. One guard after it
(`:21250`): if the iterator was carried past the top of the window the
window starts at point's own line instead.

`scroll-to-cursor!` is that now - `floor (body-height / 2)` rows back,
counting a wrapped line for the rows it takes, snapped to a line
beginning, with the guard.

### The method lesson

I found this by driving a real Emacs in a pty and reading `point`,
`window-start` and `window-end` after each key. That was the wrong order
and Chris called it: **the rule is to read the C and copy it**, not to
fit an implementation to measurements. The measurements were still worth
having as a *check* - and they are why the one-line residual below is
visible at all - but the algorithm came out of `xdisp.c`, not out of the
numbers. Doing it the other way would have produced something that
matched one terminal size.

### Open, and deliberately not tuned

My harness still differs from the Emacs run by one line: with a 12-row
terminal (body 10), Emacs scrolled back 5 lines and ours 6. Per the rule
above I have **not** adjusted the arithmetic to close that gap, because
the difference is almost certainly in what Emacs counts as
`window_box_height` (the text area minus its mode line, scroll bars,
dividers and fringes) against what our `window-body-height` returns -
a geometry question to resolve by reading, not by fitting. The
regression test in `ncurses-editor-tests.scm` asserts the *rule*
(`start == point - body/2`), not the measured number, for the same
reason.

## `M-x cd` — done (2026-10-06)

`cd` (`files.el:920`), with `cd-absolute` (`:962`), `cd-path` (`:933`),
`parse-colon-path` (`:937`) and the `locate-file` (`:1113`) it resolves
through, plus the `locate-file-internal` / `openp` search those sit on
(`lread.c:1590`, `:1756`).

`cd` is **bound to no key in GNU Emacs** - `(where-is-internal 'cd)` is
nil - so it is M-x only, and it is not bound here either.

Where each piece lives, and why:

- `locate-file-internal` went into `fileio.sld`, not a new `lread.sld`:
  it is `lread.c`'s (`:1590`) and so is the `openp` it wraps (`:1756`),
  but this is the library that holds the primitives it is built from and
  there is no `lread.sld`. Same seam as `keymap.c`'s buffer-keymap pair.
  The C's file-name-handler machinery and its native-compilation `.eln`
  swap are not carried - neither exists here - so what is ported is the
  search itself.
- Everything else is `files.el`'s and went into `files.sld`.

Two details that had to be copied rather than guessed:

- **`dir-ok`.** `openp` skips directories, so `cd` wants them found, and
  the way it says so is a predicate returning the symbol `dir-ok`
  (`files.el:940`). Without that the search would reject the very thing
  it is looking for. It is why `cd` on a *file* answers "No such
  directory: X" and not `cd-absolute`'s "is not a directory" - the
  predicate rejects it before `cd-absolute` is ever reached. Emacs
  confirms both messages.
- **The messages are one formatted string.** `(error "No such directory:
  %s" dir)` renders as "No such directory: /x"; `(error "No such
  directory: " dir)` renders without the name at all, because the second
  argument becomes an irritant. Ours formats with `~a` into a single
  string, as the tree does elsewhere.
- `cd-absolute`'s message carries a trailing slash - "/etc/hostname/: no
  such directory" - because `file-name-as-directory` put it there before
  the test was made, and `(file-exists-p "/etc/hostname/")` is false
  *because* of that slash, so it takes the "no such directory" branch
  rather than "is not a directory". Read off Emacs.

Tests: `schemacs/editor/files-tests.scm` (13), wired into
`tools/run-suites.py`, and a `cd` check in `tools/pty-check.py` that
drives M-x and reads the next `C-x C-f` prompt, since `default-directory`
is what changed and that is where it shows.

Not ported, with what each would need: the completion table `cd`'s
interactive spec installs over `cd-path` (`files.el:929-944`) - it needs
`minibuffer-completion-table` and `minibuffer-completion-predicate` as
buffer-locals that a completion function consults, which this minibuffer
does not have. Ours reads the directory the ordinary way. Also the
`access`-bit forms of `locate-file`'s PREDICATE (`executable`,
`readable`, ...), because nothing here passes one.

# The column primitives, and overwrite mode (2026-10-06)

## `scan_for_column` — one walk, not two

`move-to-column` is what `internal_self_insert`'s overwrite branch is built
on, so the bottom-up rule meant porting `scan_for_column` (`indent.c:607`)
first. Doing that turned up that **we already had the walk twice**:
`current-line-display-column` (`disp-table.sld`) was a hand-rolled copy of
it, and `current_column_1` (`indent.c:856`) is literally

```c
  EMACS_INT col = MOST_POSITIVE_FIXNUM;
  ptrdiff_t opoint = PT;
  scan_for_column (&opoint, &col, NULL, NULL, NULL);
  return col;
```

so Emacs has *one*. There is now one here: `scan-for-column` in
`indentc.sld`, answering the position, the column, and the position and
column one character before the stop as four values; `current-column` and
`current-line-display-column` are both that one call.

**Being a copy, it had drifted in two ways** — both found by asking a real
Emacs, both in the same helper:

- **A `display` property's width was added once per character it covered**
  instead of once for the whole run. A `display` string is substituted for
  the *run*, and the C jumps the scan to the run's end (`scan = endp;
  continue`). Measured on `"abcdef"` with `"XY"` displayed over 2..5:

  | | columns at positions 1..7 |
  |---|---|
  | Emacs | `0 1 3 3 3 4 5` |
  | ours, before | `0 1 3 5 7 8 9` |

- **The substituted string was measured from the current column**, where
  `check_display_width` calls `Fstring_width (val, Qnil, Qnil)`
  (`indent.c:567`) - from column **0**. A display string `"\tY"` reached at
  column 3 is 9 columns wide, not 6: the next position is column 12, not 9.

`indentc-tests.scm` (17) pins both, with Emacs's own numbers in the
expectations. The lesson is the one `AGENTS.md` already carries about
hand-rolled duplicates: the second copy cannot show you it disagrees.

## `delete-region` is one-based, and AGENTS.md said otherwise

The note under "save-excursion, the position primitives" reads:

> `delete-region' is the one exception - its callers are all internal and
> pass engine positions

**That was true when it was written (2026-10-02) and is not true now.** The
2026-10-05 conversion moved the whole engine, and everything above it, to
Emacs's one-based positions; `delete-region` passes its first argument
straight to `text-editor-set-cursor`, so it is one-based like everything
else. Measured: `(delete-region 1 2)` on `"abcdef"` gives `"bcdef"`.

Two callers still carry the `(- ... 1)` conversion the old note told them to
write - `indent-rigidly` (`indent.sld:69`) and `dired-remove-entry`
(`dired.sld:2589`). **Both are benign as they stand**, and that is worth
knowing rather than fixing blind: each deletes a range that begins just
before the text and ends just before the following newline, so it removes
the *previous* line's newline and keeps this line's instead. The result is
textually identical. They are compensating shifts, not bugs - but they are
load-bearing accidents, and the next edit to either should convert them.

## `indent-tabs-mode` defaults to `t`, and ours was `#f`

`move-to-column`'s FORCE branch fills a split tab with `indent_to`, which
obeys `indent-tabs-mode`. Emacs's default is **t** (`emacs -Q --batch`
answers `t`); ours was `#f`, so the same command filled with spaces:

| | `(move-to-column 3 t)` on `"a\tb"` |
|---|---|
| Emacs | point 4, buffer `"a  \tb"` |
| ours, before | point 4, buffer `"a       b"` |

Fixed. The one consumer that wants it off binds it itself, as Emacs's does:
`dired-insert-directory` (`dired.el:1923`, `dired.sld:719`).

# Overwrite mode (2026-10-06)

## What landed

`overwrite-mode` is `simple.el:9389`, a `define-minor-mode` over a
**buffer-local variable of the same name** (`DEFVAR_PER_BUFFER`,
`buffer.c:5480`) whose value *is* the mode: nil, `overwrite-mode-textual` or
`overwrite-mode-binary`. The behaviour is entirely
`internal_self_insert`'s overwrite branch (`cmds.c:312-400`), which is now
ported as `internal-self-insert` in a new `schemacs/editor/cmds.sld` -
`cmds.c`'s file, where `self-insert-command` and its neighbours still ought
to move to.

`overwrite-mode` and `binary-overwrite-mode` are in `simple.sld` beside
their lighters; the Insert key is bound as Emacs binds it. Ten cases, all
measured on `emacs -Q --batch` first, are in `cmds-tests.scm` (11) and match
exactly - including the two that show why the branch measures columns rather
than characters:

- overwriting a wide character with a narrow one **pads with a space**, so
  the rest of the line does not move left;
- overwriting a narrow one with a wide one **eats two characters**.

## Two departures this exposed

### 1. `insert` and `page up`/`page down` reached nothing at all

`term.sld`'s `extended-key->event` was written on a belief about the
ncurses binding that is not true. It split what it took to be a terminfo
name (`kDN3`, `kIC`) into a key and a trailing modifier digit, and looked
both up in two tables. Measured on this binding:

```
(keyname KEY_IC) = "KEY_IC"        (keyname 532) = "(unknown)"
```

So the digit was never there, the base came out as `"I"` and the digit as
`"C"`, neither table matched, and the answer was `#f`. **Insert, Page Up and
Page Down did nothing.** `KEY_LEFT`/`KEY_HOME`/`KEY_DC` and the rest were
fine only because they were also listed as explicit constants beside it.

Chris's read - "when I see great big chunks of logic just to parse a key, I
smell a hack" - was right. Emacs's `term.c` is a **flat two-column table**:

```c
static const struct fkey_table keys[] = {
  {"kh", "home"}, {"ku", "up"}, {"kI", "insertchar"}, ...
};
  for (i = 0; i < countof (keys); i++) {
    char *sequence = tgetstr (keys[i].cap, address);
    if (sequence)
      Fdefine_key (KVAR (kboard, Vinput_decode_map),
                   build_string (sequence), make_vector (1, intern (keys[i].name)), Qnil);
  }
```

No prefix, no digit, no second table. That is what `function-key-names` in
`term.sld` is now, with the left column the **keycode** rather than the
capability name, because this binding has already decoded the sequence by
the time it is asked. It is a load-time table again, where the version it
replaced had to ask the terminal at every key press.

**And then it was done properly - see `input-decode-map` below.**
`named-key-modifiers` was not wrong about Emacs; it was in the wrong
*place*, and it was reimplementing by hand what `input-decode-map` already
is. It is deleted and replaced by the real thing.

### 2. `minor-mode-alist` is two evaluations, not one

`bindings.el:979` has `(overwrite-mode overwrite-mode)` - the indicator is
the **symbol of the same name**, i.e. the *variable*, not a string. The mode
line evaluates the construct, gets the variable's value
(`overwrite-mode-textual`), and evaluates *that*, getting the string
`" Ovwrt"` (`simple.el:9384`).

Written as one step, the lighter is handed the symbol `overwrite-mode`,
matches nothing, and every lighter comes out empty - so the mode line said
`(Fundamental)` in overwrite mode and the Insert key looked like it did
nothing. `minor-mode-indicator-value` and `minor-mode-lighter` are now the
two steps, named.

## The method note worth keeping

Every expectation in `cmds-tests.scm` and `indentc-tests.scm` came from
`emacs -Q --batch` **before** the port was written, and two of the three
real bugs above were found that way rather than by reading - the
`display`-run over-count, the column-0 measurement, and `insert` reaching
nothing. Reading gave the *algorithm*; asking gave the *check*. Both were
needed, and neither alone would have found all three.

## `define-minor-mode`, and the four things it was hiding (2026-10-06)

Chris: *"so you fucking hacked the minor mode like a lazy shit head instead
of doing it properly."* He was right. `overwrite-mode` was written out by
hand - command, variable, hook, message - because `define-minor-mode` did
not exist, and that is the "improvise around the missing primitive" thing
this file forbids two paragraphs into it. Four pieces, in the order they
had to be done.

### 1. `define-minor-mode` (`emacs-lisp/easy-mmode.el`)

`schemacs/editor/easy-mmode.sld`, with `easy-mmode-pretty-mode-name`. The
macros in this tree were `syntax-rules`, which cannot *make* a name - so
`define-derived-mode` is handed its keymap's and hook's names by the caller,
and says why. `define-minor-mode` makes three (the hook and, with no
`:variable`, the variable's two accessors), and it can, because this Guile
has **`syntax-case` and `datum->syntax`**: a name built from the mode's own
identifier with the *call site's* lexical context is hygienic and lands as a
real binding in the defining library. `(define-minor-mode overwrite-mode
...)` leaves `overwrite-mode-hook` bound in `simple.sld`.

Two things had to be right and were not, first time:

- **`interactive` is a `syntax-rules` *literal* of `define-command`, not a
  binding anywhere.** Written into a template it resolves in *easy-mmode*,
  where it is unbound, and psyntax refuses the expansion: "reference to
  identifier outside its scope". Built with the call site's context it is
  the same unbound-but-named identifier a hand-written `(interactive ...)`
  is, which is what matches.
- **`current-prefix-arg` is a parameter.** The generated spec read it as a
  variable - `(if current-prefix-arg ...)` - and an uncalled parameter is a
  *procedure*, so it was always true and every press went down the
  "numeric prefix" branch: `uarg->integer` then raised "U-argument cannot be
  cast to integer" and the key silently did nothing. It must be `(current-prefix-arg)`.

`called-interactively-p` (`eval.c`) is ported to make the message right: the
generated command echoes `"%s %sabled%s"` only when it was called through
`interactive-proc`, which now binds a flag around every interactive call.
A programmatic `(overwrite-mode 1)` stays silent, as Emacs's does - verified:
`emacs -Q --batch` with `(call-interactively 'overwrite-mode)` prints the
messages and a plain call prints nothing.

**The hand-written version had the wrong words.** The real ones, measured,
are `"Overwrite mode enabled in current buffer"` and
`"Binary-Overwrite mode enabled in current buffer"` - `pretty-name` keeps
the " mode". The hand-written ones said "Overwrite enabled". And the
hand-written toggle enabled on a bare call where Emacs's *toggles* (the
macro's interactive form passes the symbol `toggle` when there is no prefix).

### 2. `add-minor-mode` (`subr.el`), and where `minor-mode-alist` lives

`*minor-mode-alist*`, `*minor-mode-list*` and `add-minor-mode` are in
`subr.sld`. **Placement is a departure**: Emacs declares the alist in
`bindings.el`, and this tree keeps the other mode-line variables there too
(`*mode-line-format*` is in `xdisp.sld`). It is here because of the import
graph - `xdisp.sld` imports `simple.sld`, which imports `subr.sld`, and the
alist has to be reachable from `simple.sld`, where `define-minor-mode`
expands.

`overwrite-mode` passes **no** `:lighter` - also as in Emacs: the entry
`(overwrite-mode overwrite-mode)` that `bindings.el:979` puts in the alist
is already there, and `add-minor-mode` with a nil name leaves it alone.

### 3. `input-decode-map`, and the end of the modifier parsing

The finding that made this possible, and it was a *measurement*:

```
(getch) for "\e[1;3A"  ->  573
(keyname 573)          ->  "kUP3"      ;; a terminfo name
(tiget "kUP3")         ->  "\e[1;3A"   ;; the sequence, back again
```

So `keyname` has **two shapes**: for the keys ncurses decodes to a constant
it answers `"KEY_IC"`, and for everything above that range it answers a
*terminfo* name. The version this replaces assumed the terminfo shape
everywhere, split `k`+base+digit, and matched nothing for the standard keys
- which is why Insert, Page Up and Page Down reached nothing at all.

The other half is that `tiget` turns the name back into the escape
sequence, and **that is what Emacs keys `input-decode-map` on**. So:

- `xterm.sld` now has `*input-decode-map*` - `xterm-rxvt-function-map` and
  `xterm-function-map` from `term/xterm.el:211-661`, 255 entries,
  **transcribed by a script**. Its own header used to say the key maps were
  "not ported ... the keys come through ncurses's terminfo lookup here";
  they are ported now, and the terminfo lookup is the road to them rather
  than a replacement for them.
- `term.sld` has `%sequence->event`: `(keyname ev)` -> `(tiget name)` ->
  the sequence -> the map. **No modifier is parsed out of anything.**

Verified at a pty against the tree's own `key-event->key`:

```
573 -> M-up      574 -> M-S-up      575 -> C-up
331 -> insertchar    339 -> prior    258 -> down
```

(`'M-S-kp-subtract` and its like - 255 entries full of them - are Emacs's
own spelling: `(define-key map "\eO4m" [M-S-kp-subtract])` is verbatim at
`xterm.el:476`. The whole thing is one *event symbol*, not a modifier list
this port invented.)

### 4. The cmds.c command cluster, and two compensating shifts

`self-insert-command`, `self-insert-tab`, `forward-char`, `backward-char`,
`beginning-of-line`, `end-of-line` and `delete-char` moved from
`simple.sld` to `cmds.sld`, which is `cmds.c`'s file; `simple.sld` imports
them from there and re-exports them, so every existing importer is
unchanged.

The two `(- ... 1)`s in `indent-rigidly` and `dired-remove-entry` are gone.
They were compensating for a `delete-region` that took engine positions, and
it does not - both now read as the Elisp they came from.

---

## The pair bug: a decoder that answered a dotted pair

Worth its own note because it cost two rounds of false conclusions and the
evidence was in front of me both times.

`key-event->key`'s new else-branch was written

```scheme
(let ((k (assq ev function-key-names)))
  (and k (cdr k))                   ; <- this line does nothing
  (or k (%sequence->event ev)))     ; <- and this returns K, the pair
```

so Insert answered `(331 . insertchar)` - a **pair** - where the event
should have been the symbol `insertchar`, and the keymap lookup then did
nothing with it. The probe printed it plainly:

```
(331 (331 . insertchar))
```

and I read it as `(code result)` with `result` = `insertchar`. It is
`(code result)` with `result` = the pair. `(if k (cdr k) ...)` is the fix.

**And it produced a wrong finding.** Page Down scrolled and then the editor
died with

```
In procedure car: Wrong type argument in position 1 (expecting pair): next
```

which I diagnosed as a pre-existing keymap bug - "a named key reaching a
command whose interactive spec is `"P"`", with a table of five isolating
observations and a paragraph in this file about holding the keys back. All
five observations were true and the conclusion was wrong: `next` was the
*cdr of the pair the decoder had just returned*, and `car` of it is exactly
the error. With the pair fixed, Page Down and Page Up work and the
`pagedown` check passes. The keys were never held back and this file no
longer says they were.

The lesson is the one about naming-step tracing: when the evidence is a
printed value, read the *shape* of it before drawing a conclusion from it.

## Scrolling down one line at a time — the other half of the recentring rule

Chris, from using the editor: *"In emacs if I go down one line at a time,
when I hit the bottom it scrolls up half a page or something. In schemacs if
I go down one line at a time it seems to scroll always 2 lines at the
bottom."*

Right again, and it is the same rule as the recentring note above - applied
in the direction that note did not cover. `scroll-to-cursor!` recentred when
point went *above* the window and scrolled by a couple of lines when it went
*below*, as if the two were different decisions.

**They are one decision, and the C says so in the guard rather than in the
body.** `try_scrolling` - the scroll-by-a-few-lines path, the one that would
move the window by a single line - is not even *called* at the default
settings (`xdisp.c:21109`):

```c
  if ((0 < scroll_conservatively
       || 0 < emacs_scroll_step
       || temp_scroll_step
       || NUMBERP (BVAR (current_buffer, scroll_up_aggressively))
       || NUMBERP (BVAR (current_buffer, scroll_down_aggressively)))
      && CHARPOS (startp) >= BEGV && ...)
    { ... try_scrolling ... }

  /* Finally, just choose a place to start which positions point
     according to user preferences.  */
 recenter:
```

`scroll-conservatively` and `scroll-step` are both 0 and the two
`aggressively` variables are both nil, so the condition is **false** and
control falls straight through to `recenter:` whichever direction point left
by. And `recenter:` sets `centering_position = window_box_height (w) / 2`
(`:21230`) unless the conservative/aggressive branch above it is taken,
which it is not.

So the default Emacs scrolls by *one line* never; it **recentres**, and the
text moving up about half a page on each C-n at the bottom is exactly what
that looks like from the outside. Scrolling by one line is what a
*configured* Emacs does - `scroll-step 1`, or `scroll-conservatively` over
100 - and those settings are the branch this port does not have.

`back-up-from-cursor` is gone: its only caller was the downward case, and
the downward case is `recenter-window-on-cursor!`, which is the upward
case's walk with a name. `scroll-to-cursor!`'s own job is now only the one
thing the decision needs from the display - **whether the cursor's own row
is on the screen**, which is a question about rows and not about lines, and
is why the row walk is still there.

`ncurses-editor-tests.scm` has the mirror of the upward test: walk down one
line at a time until the window has to move, and assert the *rule*
(`start == point - body/2`), not a measured number.

# `eval-expression` (2026-10-06)

## What it is, and the one departure

M-: prompts `Eval: `, evaluates what is typed, and echoes the value; an
error fills `*Backtrace*`. That is `simple.el:2140` with
`eval-expression-print-format` (`:2044`), `read--expression` (`:2063`) and
the variables they read.

**The evaluator is Scheme's, and that is the departure.** Emacs's
`eval-expression` evaluates Emacs Lisp - `(eval (let ((lexical-binding t))
(macroexpand-all exp)) t)' (`:2172'). This editor is a Scheme program, so
what the minibuffer reads is a Scheme expression and `(scheme eval)''s
`eval' runs it. Chris's call, and the header of the backtrace says
`Debugger entered--Scheme error:` where Emacs says `--Lisp error:`, which
is the same departure showing through.

It lives in `minibuffer.sld`, not `simple.sld`, for the reason
`goto-line`, `zap-to-char` and `set-fill-column` do: `simple.sld` is
*beneath* the minibuffer library and a command that prompts cannot live
there.

## Where the expression is evaluated, and how that was found

`(interaction-environment)' was the first answer and it was wrong: under
`--r7rs' it is a minimal environment, and `(+ 40 2)' answered **"Unbound
variable: +"**. What is used is `(current-module)' - the module current
when the command runs, which is where the editor's own bindings are. A
name the editor defines is reachable from M-: as a result, which is the
useful behaviour and the nearest thing to Emacs evaluating in the current
buffer's context.

## The backtrace, which is possible after all

Chris asked whether a backtrace is even possible with Scheme `eval'. It
is, and the reason is the same one that makes Emacs's work: **the debugger
does not invent the frames, it asks the runtime.** Emacs asks its own
backtrace machinery; this asks Guile's.

The one thing that has to be right is *when* the stack is taken. A `guard`
unwinds before its handler runs, so it has no frames to show.
`with-exception-handler` calls its handler **on the raising stack**, so
that is where `(make-stack #t)' can still see them - and a continuation
captured outside escapes with the condition so the header can name it:

```scheme
(call/cc
 (lambda (escape)
   (with-exception-handler
    (lambda (e) (set! stack (make-stack #t)) (set! failed #t) (escape e))
    (lambda () (eval exp (%eval-expression-environment))))))
```

`display-backtrace' then writes the frames, which are inserted into the
buffer Emacs uses - `*Backtrace*' (`debug.el:212'), with
`debugger--insert-header''s `error' case (`:412') as its first line.

**Guile's condition messages are format templates.** `error-object-message'
answers `"Unbound variable: ~S"' with the name in
`error-object-irritants', so the two are put back together - with `~S' and
`~A' lowered to the directives Guile's own `format' takes. Without that
the header read `Unbound variable: ~S', which is what the first version
printed.

## `prin1`, which came first

`eval-expression` is `prin1` with `print-length` and `print-level` bound
(`:2182'), and the tree's `prin1` was `(write val stream)' - Guile's
`write', which says `#t' where Lisp wants `t', knows nothing of this
tree's `nil', and has no `print-length' at all. So the port started there:
`schemacs/elisp-eval/print.sld', mirroring `print.c' - `print_object' and
the four variables its default path reads.

Twelve cases, each measured on Emacs 31.1 first, in `print-tests.scm' (29):

| | Emacs | ours |
|---|---|---|
| `(prin1-to-string nil)` | `"nil"` | `"nil"` |
| `(prin1-to-string t)` | `"t"` | `"t"` |
| `(prin1-to-string '(quote a))` | `"'a"` | `"'a"` |
| `print-length 2` on `(1 2 3 4)` | `"(1 2 ...)"` | `"(1 2 ...)"` |
| `print-level 1` on `(1 (2 3))` | `"(1 ...)"` | `"(1 ...)"` |
| `print-quoted nil` on `'(quote a)` | `"(quote a)"` | `"(quote a)"` |
| `(prin1-to-string (intern "?"))` | `"\\?"` | `"\\?"` |

**Not carried**, each because nothing here produces the value:
`Lisp_Vectorlike' and its dozen sub-cases (buffers, windows, markers,
overlays, char-tables, hash tables, records, subrs), and with them the
`#<...>' forms; `print-gensym'; `print-circle' and the `#N=' / `#N#'
notation - a circular structure is reported rather than abbreviated,
which is the C's own behaviour with `print-circle' nil;
`print-escape-nonascii', `print-escape-multibyte' and
`print-escape-control-characters', whose defaults are nil.

**One data-model difference the printer shows.** Emacs has one empty
thing: `()` and `nil` are the same object, so `(prin1-to-string '())` is
`"nil"`. This tree has two - its empty list is Scheme `'()` and its `nil`
is a `sym-type` - and `(eq? (scheme->elisp '()) nil)` is **`#f`**. So
`'()` prints `"()"` here and `"nil"` there. That is the tree's data model,
not the printer's; it is named here because M-: output is where a user
would first see it.

## The piece whose absence made it look broken

Chris, using it: *"it mostly works... it doesn't make a backtrace buffer
though."* It did - for a *runtime* error - and the case he was hitting was a
**read** error, which never reached the debugger at all, because the read
happened after the minibuffer had already closed.

Emacs cannot get into that state: `read--expression-map` binds RET to
`read--expression-try-read` (`simple.el:2083`), which reads the text *while
the minibuffer is still open* and, on failure, reports the error and
**refuses to exit**. So a malformed expression is a prompt-time complaint,
not an evaluation error, and the backtrace is only ever for what `eval`
raised - which is the right division and was missing here.

Both are now carried, and the three cases behave as they should at a pty:

| typed | what happens |
|---|---|
| `(+ 1` | minibuffer stays open, `Eval: (+ 1 [<reader error>]` - `minibuffer-message`'s enclosure |
| `(car (quote ()))` | `*Backtrace*` fills and displays |
| `(no-such-thing)` | `*Backtrace*` fills and displays |

`read--expression-map` needs its *parent* set: a map handed to
`read-from-minibuffer` replaces `minibuffer-local-map` rather than adding
to it, so `(set-keymap-parent map minibuffer-local-map)` is what keeps C-g
and the history keys - which is Emacs's own line.

**The reader's words are Guile's.** Emacs says "End of file during parsing"
and "Invalid read syntax"; ours says `#<unknown port>:1:5: unexpected end of
input while searching for: )`. Same class of message, the runtime's text
rather than Emacs's, because the reader is the runtime's.

## Not ported from `eval-expression`

`eval-expression-get-print-arguments' and the prefix-argument behaviour it
serves - `C-u` to insert the value into the buffer rather than echo it,
`C-u 0` for no truncation, `-1` for the widest character limit.
`eval-expression-print-level' and `eval-expression-print-length' likewise:
the Scheme printer has no truncation to bind. And moving point to the
reader's error in `read--expression-try-read', which needs a reader that
can be asked where it stopped - see above.

## The backtrace buffer's three missing properties (2026-10-06)

Chris, using it: *"eval-expression should have a mini-buffer history ... and
the Backtrace window .. it should be a readonly window, and it should accept
"q" as a keystroke which closes that window. Also when the error happens the
backgrace window should gain focus."*

All three, and each is Emacs's own mechanism rather than a special case.

**The history** was a bug of mine with a good lesson in it. The first
`read--expression-map` was built with `(set-keymap-parent map
minibuffer-local-map)`, which is Emacs's own line - and M-p answered
`; undefined key: (meta #\p)`. **This tree's lookup does not follow a
keymap's parent**: `keymap-lookup` walks a map's own *layers* and then the
next map in `lookup-keymaps`' list, and a parent is neither. The bindings
are copied instead, from one shared `minibuffer-local-bindings` list, so
the two maps cannot drift apart. Copying is also what the map means:
`read-from-minibuffer` *replaces* `minibuffer-local-map`, so whatever the
expression prompt does not carry it loses.

**Read-only and `q`** are `special-mode`, not two settings. Emacs's
`debugger-mode` (`debug.el:624`) derives from `backtrace-mode`
(`backtrace.el:830`) derives from `special-mode` (`simple.el:589`), and
`special-mode` is what sets `buffer-read-only` and gives the buffer its
map; `debugger-mode-map` then refines `q` to `debugger-quit`, whose body
at recursion depth 0 is `quit-window`. So the buffer runs `(special-mode)`,
takes the mode name "Debugger", and gets a `debugger-mode-map` whose parent
is `special-mode-map` and whose `q` is `debugger-quit`.

**Focus** is one function: `pop-to-buffer` selects the window and
`display-buffer` does not. Emacs's debugger uses `pop-to-buffer`
(`debug.el:270`), which is why a backtrace has the keyboard the moment it
appears.

And a fourth thing that came out of testing it: **point must go to the
top**. `debugger-setup-buffer` ends with `(goto-char (point-min))` and a
search for the header's colon (`debug.el:372`, "Place point on stack frame
0"), and without it the buffer opens scrolled to its *last* frame - the
backtrace is longer than the window, so the header the user is meant to
read is off-screen. That is what the first version did, and the pty check
is what caught it.

### Two arities that are not Emacs's

- `char-after` here takes its position *required*; Emacs's `(char-after)`
  defaults to point.
- `forward-char` here is the *command*, so its count is required; Emacs's
  is the C primitive `(&optional N)`, defaulting to 1.

Both were found by the port failing with "Wrong number of arguments", and
both are departures in `editfns.sld` and `cmds.sld` respectively rather
than in this command. **`forward-char`'s is worth fixing**: `(forward-char)`
with no argument is valid Emacs and would fail here.

### Still empty: `special-mode-map`

`special-mode-map` in `simple.sld` is `(km:keymap '*special-mode-map*)` -
no bindings at all, with a note saying Emacs's carries the `special-mode`
bindings. It does:

```elisp
(defvar-keymap special-mode-map
  :suppress t
  "q" #'quit-window  "SPC" #'scroll-up-command  "S-SPC" #'scroll-down-command
  "DEL" #'scroll-down-command  "?" #'describe-mode  "h" #'describe-mode
  ">" #'end-of-buffer  "<" #'beginning-of-buffer  "g" #'revert-buffer)
```

So `q`, SPC, DEL, `<` and `>` are missing from **every** special mode -
`dired`, the Buffer Menu and now the backtrace buffer - and `g` with them,
which is the binding the Buffer Menu's note already says it inherits. This
was not fixed here because `describe-mode` does not exist and `revert-buffer`
lives in `files.sld`, which is above `simple.sld`; and `:suppress` needs a
way to make a buffer's map refuse printing characters, which the tree has
no spelling for. It wants its own pass, and it is more than the backtrace
buffer: it is dired and the Buffer Menu too.

## `eval-region` (2026-10-06)

Chris: *"can you implement eval-region. It seems to have silent output,
unless there is an error in which case you just get minibuffer message."*
Both halves of that are the C, and they are two different mechanisms.

**It is `lread.c:2420`, not `simple.el`** - `Feval_region`, over
`readevalloop` (`:2132`). Emacs has no `lread.el`, so there is no
`lread.sld` to put it in; it sits in `simple.sld` beside the other
commands that work on a region, which is the same seam
`locate-file-internal` took into `fileio.sld`.

**Silence** is the PRINTFLAG. `Feval_region` binds `standard-output` and
calls `readevalloop` with `!NILP (printflag)`; the loop ends with

```c
      if (printflag)
	{
	  Vvalues = Fcons (val, Vvalues);
	  if (EQ (Vstandard_output, Qt)) Fprin1 (val, Qnil, Qnil);
	  else Fprint (val, Qnil);
	}
```

and the interactive spec is `"r"` - **two** arguments where the function
takes four - so every interactive call passes a nil PRINTFLAG and nothing
is printed. (The discard stream Emacs binds `standard-output` to is the
*symbol* `symbolp`: a function stream is called with each character, and
`symbolp` is a function that throws its argument away.)

**The minibuffer message on an error is not this function's either.**
`Feval_region` has no handler at all; what catches the error is the command
loop's `report-command-error!`, which is what any command's error becomes.
That is the difference from `M-:` and it is deliberate on Emacs's side:
`eval-expression-debug-on-error` says "If non-nil set `debug-on-error' to t
in **`eval-expression`**" - that command and nothing else - so a bad region
gets an echo-area message and no backtrace, and a bad expression gets a
backtrace. Both are now checked at a pty.

`eval-region` is **M-x only**, as in Emacs: `(where-is-internal
'eval-region)` is nil.

### Not carried

- **The region is read from a string**, where Emacs narrows the buffer and
  reads from point. The docstring's "This function does not move point"
  comes free that way; the narrowing is not needed.
- **`standard-output` is a string port**, not a void one - Guile has no
  `open-output-void` and no `void-port` (checked). What accumulates is
  dropped, so it is invisible, but it is not the same object.
- **`read-function`**, the fourth argument, which lets a caller supply its
  own reader. Nothing here would pass one.

## `move_point`: forward-char was two departures, not one (2026-10-06)

Found by the backtrace port, which calls `(forward-char)` with no argument
the way `debugger-setup-buffer` does, and got "Wrong number of arguments".
Reading `cmds.c` showed the arity was the smaller half.

`forward-char` and `backward-char` are both `move_point (n, forward)`
(`cmds.c:40`):

```c
  if (NILP (n)) XSETFASTINT (n, 1); else CHECK_FIXNUM (n);
  new_point = PT + (forward ? XFIXNUM (n) : - XFIXNUM (n));
  if (new_point < BEGV) { SET_PT (BEGV); xsignal0 (Qbeginning_of_buffer); }
  if (new_point > ZV)   { SET_PT (ZV);   xsignal0 (Qend_of_buffer); }
  SET_PT (new_point);
```

Three things, and this tree had none of them. Two of the three are
departures a *test* could not have caught, because the port and Emacs
agreed on every in-range move:

1. **N is optional** and a nil N is 1. Ours was a required parameter, so
   `(forward-char)` was an error. This is the one that was found.
2. **It stops at the boundary** - ours did that much, by way of
   `text-editor-move-cursor`'s clamping.
3. **...and then signals** - "On reaching end or beginning of buffer, stop
   and signal error." Ours clamped and said nothing, so a command that ran
   off the end succeeded quietly where Emacs fails. `move_point` is the
   only thing in this tree that raises `beginning-of-buffer` and
   `end-of-buffer`; nothing needed the signal yet, which is why it had gone
   unnoticed.

Both are fixed, in one `%move-point` that is the C's four lines, and
`forward-char`/`backward-char` are `(0, 1, "^p")` over it. The measured
table is in `cmds-tests.scm` (17): both ends, past the end, no argument, a
nil argument, and a negative N.

**The neighbouring commands have the same shape and were not touched.**
`beginning-of-line` and `end-of-line` are also `(0, 1, "^p")` in `cmds.c`,
and their N is not merely optional: `(beginning-of-line N)` moves forward
N - 1 lines first, and this tree's take no argument at all, so the call is
an error *and* the behaviour is missing. That is a bigger change than an
arity default - it changes what the command does - so it is on the record
here rather than guessed at.

## `beginning-of-line`/`end-of-line`, and the two bugs underneath (2026-10-06)

The arity fix was one line each; finding it uncovered two more, one level
down each time. This is the bottom-up rule paying for itself, and it is
worth reading as a sequence.

**The commands.** Both are `(0, 1, "^p")' in `cmds.c' and each is one call
over the N-line arithmetic:

```c
  if (NILP (n)) XSETFASTINT (n, 1); else CHECK_FIXNUM (n);
  SET_PT (XFIXNUM (Fline_beginning_position (n)));
```

This tree's took **no argument at all**, so `(end-of-line 0)' was an error
*and* the behaviour was missing - N moves forward N - 1 lines, 0 and
negatives move back.

**Bug 1, under `line-end-position'.** It was `forward-line (- n 1)' and then
the line's end, where the C is `(make_fixnum (eol (n)))' - and `eol' is
`editfns.c:723', which this tree *already had* as the engine's `eol',
complete with the `count - (count <= 0)' adjustment. So the primitive was
right and the wrapper did not use it. The two agree for N of 1 and above
and differ below: `(line-end-position 0)' at the first line is position 1
in Emacs - the backward scan runs off the beginning of the buffer and stops
there - and was the end of line 1, position 4. `line-beginning-position'
had the same shape over `bol' and is now that one call too; it happened to
agree on every N anyone passes, which is exactly the condition under which
a second implementation survives.

**Bug 2, under `eol' -> `find_before_next_newline' -> `find_newline'.**
With the wrapper fixed, one row was still wrong, and the primitive
underneath answered it:

```
(find-newline ed 9 -2 #f)  ->  pos 5, found -1     ;; Emacs: found -2
```

`find-newline-backward' returned a **hardcoded `-1'** for the count of
boundaries found, however many it had crossed. That count is the C's
`counted' (`search.c:942', `*counted -= count'), and
`find_before_next_newline' reads it to decide whether to step back onto the
newline - so a wrong count is a wrong position, one boundary out. It was
invisible for as long as nothing asked for a backward count below -1:
`bol' passes exactly -1 and `eol' reached -2 only through the N the
commands did not have.

The fix is `-1' -> `(- found 1)'. **My first attempt fixed the wrong
half** - I changed the loop's termination from `(= left -1)' to
`(= left 0)' and made every backward scan one boundary *longer*, which the
probe showed at once. The termination test is the C's `if (++count == 0)'
and was right; the returned count was not.

All eighteen rows of the measured table (`cmds-tests.scm', 22) match Emacs
31.1, and all 29 suites pass.

## `special-mode-map`, and the keymap parents that did nothing (2026-10-06)

Two things, and the second is the one that mattered. Chris asked for the
map; filling it turned out to be pointless without the other.

**The lookup did not follow a keymap's parent.** `keymap-lookup-binding-key'
in `(schemacs keymap)' walks `(keymap->layers-list keymap)' and stops:

```scheme
(let loop ((layers (keymap->layers-list keymap)))
  (cond ((null? layers) #f)
        (else (let ((result (keymap-layer-lookup-binding-key (car layers) binding)))
                (or result (loop (cdr layers)))))))
```

A parent is not a layer. Emacs walks `keymap-parent' after the map itself,
and that walk is the *whole* mechanism of keymap inheritance - it is what
`define-derived-mode''s `(set-keymap-parent CHILD-map (current-local-map))'
means, and what dired's `(set-keymap-parent map special-mode-map)' means.

So every parent in this tree was decorative, and nothing showed it because
the modes that need a key tend to bind it themselves: the Buffer Menu binds
`g' explicitly rather than inheriting it, which is why the note saying `g'
"is inherited from `special-mode-map'' was true of Emacs and not of here.

`lookup-keymaps' now expands each map through `%keymap-and-parents'
(`keyboard.sld'), nearest first, and a child's binding shadows its
parent's - which is the point.

**Then the map.** GNU Emacs's (`simple.el:580'):

```elisp
(defvar-keymap special-mode-map
  :suppress t
  "q" #'quit-window  "SPC" #'scroll-up-command
  "S-SPC" #'scroll-down-command  "DEL" #'scroll-down-command
  "?" #'describe-mode  "h" #'describe-mode
  ">" #'end-of-buffer  "<" #'beginning-of-buffer
  "g" #'revert-buffer)
```

Six of the nine are bound at the end of `simple.sld' - where the commands
they name are defined, a binding being a value. **Not carried**: `?' and
`h' are `describe-mode', which does not exist here; `g' is `revert-buffer',
which is `files.sld''s and that library is above this one; and `:suppress t'
- `(suppress-keymap map)' - which makes a special buffer's printing
characters *undefined*, and which needs a layer a buffer's own map can put
over the self-insert fallback, that being a layer of the global map.

The pty check is the Buffer Menu's `q': open the list, select its window,
and the window closes - which is only possible if the binding is inherited,
since the Buffer Menu binds no `q' of its own.

### A departure found while testing it

`quit-window' on a frame's **only** window buries the buffer and stops:

```scheme
(bury-buffer buffer)
(if (> (length (window-list)) 1) (delete-window window) #f)
```

Emacs's `quit-window' also switches that window to the previous buffer
(`switch-to-prev-buffer'), so the dired buffer being buried shows something
else. Ours leaves it showing the buried buffer, which is why `q' in dired
looks like it did nothing. Not fixed here; named because it made the first
version of this check read as a failure when the inheritance was working.

# The character set machinery, first pass (2026-10-06)

Chris: *"now that all our characters are in a u32 array, it's critical we
have good character set machinery to make sure it is saved in the right
format. It's a confusing area, but I'm guessing we need work."* He was
right, and then he was right about the shape of it too - *"(1) detecting
the char set, (2) saving the char set somewhere in memory. (3) possibly
changing the char set in some circumstances. (4) writing the file,
presumably one char at a time through a guile text port."*

## The state before this

The tree had the **EOL half** of a coding system - `line-break-*` - and no
character-coding half at all. `buffer-file-coding-system` held a
`line-break-*` value where Emacs holds `utf-8-unix`; that is the seam.
Reading and writing went through the *default* port encoding, so every
file was treated as UTF-8 and `café naïve` in Latin-1 came in as
`(99 97 102 65533 ...)`: both accented bytes replaced by U+FFFD, **and
written back out that way**. Emacs on the same file gives
`(99 97 102 233 ...)` and `iso-latin-1-unix`.

## The codecs are Guile's, and I nearly missed that

My first framing was that Guile's port "destroys characters". Chris:
*"I don't know why you're telling me that the guile default port destroys
characters, because you wouldn't be writing to the default port would you.
You'd be opening a port and specifying the character set right?"* Right.
Nothing is destroyed; we never chose. Measured both directions:

| | bytes |
|---|---|
| `#:encoding "ISO-8859-1"` | `63 61 66 e9 20 6e` |
| `#:encoding "UTF-8"` | `63 61 66 c3 a9 20 6e` |
| Emacs, `utf-8-unix` | `63 61 66 c3 a9 20 6e` |

So `coding.c`'s twelve thousand lines are almost entirely *decoder
implementations we skip* - the UTF-8 machinery, the ISO-2022 state
machines. This is the "integrate core guile functions" case in AGENTS.md,
and what is left to port is the vocabulary, the buffer's choice, and the
detection.

## What landed

- **`character.sld`**: the eight-bit representation (`CHAR_BYTE8_P`,
  `BYTE8_TO_CHAR`, `CHAR_TO_BYTE8`, `CHAR_TO_BYTE_SAFE`,
  `UNIBYTE_TO_CHAR`, `MAX_5_BYTE_CHAR`) - five one-liners, and the one
  piece of the whole area that has to be written by hand, because "do not
  convert" is not a charset conversion and no iconv name expresses it.
- **`coding.sld`** (new, mirrors `coding.c`): the coding-system record and
  table with Emacs's naming - `utf-8`, `iso-latin-1`, `us-ascii`,
  `no-conversion`, `raw-text`, `utf-16`/`-le`/`-be`, each with its
  `-unix`/`-dos`/`-mac` variants derived the way Emacs derives them -
  `find-coding-system`, `coding-system-p`, `coding-system-base-name`,
  `coding-system-change-eol-conversion`, the EOL/g`line-break-*` tables,
  and `decode-coding-string`/`encode-coding-string` over iconv.
- **`coding-tests.scm`** (16), every expectation measured on Emacs 31.1.

## Two things only measuring could have settled

**Emacs does not fail on undecodable bytes.** `(decode-coding-string
(unibyte-string 99 97 102 233) 'utf-8)' is `"caf\351"` - the *eight-bit*
character, not an error - and reading the file gives the same. That is
`DECODE_COMPOSITION_FAILURE` in the C: the decoder writes the raw bytes out
as byte characters and carries on. Guile's iconv refuses the input
outright, so `%decode-with-fallback` walks the bytes *only when iconv has
refused the whole input*, taking the longest sequence that decodes on its
own and making a byte character of one that does not.

**A Scheme string cannot hold the eight-bit characters.** `(integer->char
4194281)` is out of range; Guile's ceiling is `#x10FFFF`. Our `u32vector`
holds it. So `decode-coding-string` returns a **`u32vector` of code
points** where Emacs's returns a string - deviation #3 surfacing at the API
rather than in the store - and `decode-coding-region` (which Emacs has and
this does not yet) will be a *copy* rather than a conversion.

## The measured table these are written against

| file | coding system | Emacs | now |
|---|---|---|---|
| `café naïve` Latin-1 | `iso-latin-1` | `(99 97 102 233 ...)` | same |
| ... | `no-conversion` | `(99 97 102 4194281 ...)` | same |
| ... | `utf-8` | the same, **not an error** | same |
| `AB` UTF-16LE BOM | `utf-16` | `(65 66)` | same |

...and `no-conversion` round-trips the Latin-1 file byte for byte, which
is the safety net: a file we cannot classify can be read and written
without being mangled.

## Found on the way

`find-coding-system` walked its table with `(cond ((not cs) #f) ...)` -
**an empty list is *true* in Scheme** where Elisp's `nil` is false, so the
walk ran off the end into `(car '())`. It only showed because a *string*
argument reached it, which is the class AGENTS.md already has a section
on. `null?` and not `not`.

## Still to do, in the order Chris named

1. **Detecting** (`set-auto-coding`, `detect-coding-region`,
   `find-operation-coding-system`): the `-*- coding: -*-` tag, the
   local-variables block, the BOM, `file-coding-system-alist`.
2. **`buffer-file-coding-system` holding a real coding system** - the
   variable absorbs the existing `line-break-*` machinery as its EOL half
   rather than sitting beside it - plus the write-back of
   `last-coding-system-used` after a successful save, which is what makes
   the choice stick.
3. **Changing it** (`set-buffer-file-coding-system` C-x RET f,
   `universal-coding-system-argument` C-x RET c,
   `revert-buffer-with-coding-system`).
4. **`find-file`/`save-buffer` using it** instead of the default port.
   Until this is done none of the above changes what a user sees, and the
   two files above are still being mangled.

Not carried from `coding.c`, each named where it would go: `utf-8-emacs`
(Emacs's five-byte form, which iconv has no equivalent of, so it is the
one codec that would be hand-written), `undecided` as a *deferred* choice,
`:charset-list` and the rest of the plist, and the ISO-2022/CJK families.

## Reading and writing a file, one character at a time (2026-10-06)

The half of the coding work that has no exception in it, and it is smaller
than the two versions I proposed before it. Chris found both of the pieces
I had wrong.

### "You wouldn't be writing to the default port" - and the mixed port

I had framed Guile's port as destroying characters. It does not; we never
chose an encoding. Then I said a coding walk needed one path for chars and
another for bytes. Chris:

> I believe that you can set an encoding on a binary port, then you can
> write bytes to it but if you write a char to it it will use the encoding,
> so you can mix and match. (set-port-encoding! port "Shift_JIS")

Measured, and he is right - a port with "UTF-8" set, written to with
`write-char #\a`, `put-u8 #xe9`, `write-char (integer->char 233)`,
`write-char #\z`, gives `61 e9 c3 a9 7a`; the byte went out untouched and
the two characters were encoded. Read back with `read-char` and `get-u8`
mixed the same way it answers `#\a`, `233`, `#\é`, `#\z`.

### "Catch and record the bad bytes" - and the conversion strategy

I said reading could *not* work that way, because `read-char` substitutes
`U+FFFD` for a byte it cannot decode and you never learn it happened.
Chris:

> I think it might be possible to read the char through the input port, but
> still catch and record the bad bytes when they occur.

with `(set-port-conversion-strategy! in 'error)`. That is the missing
setting: by default the strategy *substitutes*, and `'error` makes
`read-char` signal instead, with the offending byte still on the port -
which is what makes the recovery exact. Measured over three files:

| bytes | Emacs 31.1 | Guile, `'error` + `get-u8` |
|---|---|---|
| `41 c3 28 42` | `65 4194243 40 66` | same |
| `41 e2 82 42` | `65 4194274 4194178 66` | same |
| `41 c3 a9 42` | `65 233 66` | same |

### What a bad sequence becomes - Chris's question

> what you will do with it so it comes out again... You store them together
> in our u32 array? But our u32 array is an array of UTF-32 right? Isn't it
> possible that those 2 bytes which are illegal in UTF8 are actually legal
> in UTF32? Or you have a special strategy for that with using the high
> bits or something?

The high bits, and it is Emacs's `character.h`:

- **One code point per byte**, never a sequence stored together. The
  `41 c3 28 42` row is the proof: the C3 became one byte character and the
  `28` then came out as an ordinary `(` - **the scan carries on from the
  next byte**, so a byte that is valid on its own is not dragged down with
  the sequence it was in.
- **A byte is not stored as itself**, because it *would* be a legal code
  point - `0xE9` is `é` in Latin-1, and a buffer could not tell the two
  apart. It is stored as `0x3FFF00 + byte`, a range above
  `MAX_5_BYTE_CHAR` (`0x3FFF7F`), where `CHAR_BYTE8_P` can recognise it and
  where no character can ever live. So writing it back is unambiguous: the
  test is the range, not a guess.

### What landed

`schemacs/editor/coding.sld` gained `coding-setup-port!`,
`coding-read-char` and `coding-write-char` - the stream walk `decode_coding`
and `encode_coding` are - and `coding-tests.scm` (21) has the three files
above plus the round trip: **`no-conversion` reads the Latin-1 file and
writes back `99 97 102 233 32 110 97 239 118 101 10` - the original
bytes.**

Two Guile details worth keeping:

- `write-char` takes the **character first and the port second**, the
  opposite of `put-u8`; and `read-char` takes the port first like
  `get-u8`. Getting that backwards was a "Wrong type argument" that named
  a port where a character was expected, which is at least honest about
  which of the two it is.
- `read-char` answers a *character* and `byte8-to-char` an *integer*, so
  the walk converts the first with `char->integer` and every answer is a
  code point. That is not tidiness: a byte character is precisely the
  value that cannot be a character, so a caller must never have to ask
  which it got.

## Inserting code points, and the full round trip (2026-10-06)

The walk answers *code points* - including byte characters - and the insert
path only took strings, so a decoded file had nowhere to go. This is the
wall I hit two passes ago and mistook for a blocker on everything; it is
one function.

`buffer-text-insert-code-points!` is the sibling of
`buffer-text-insert!`, the same loop without `char->integer`, taking a
`u32vector` - the store's own type, so it is a copy rather than a
conversion. Emacs needs no such pair, because its strings hold its
characters; here the string form is the special case.

**And the round trip through a real buffer, measured:**

```
file bytes                  41 c3 28 42
  decode as utf-8         -> buffer holds (65 4194243 40 66)   <- Emacs's answer
  encode back from buffer -> 41 c3 28 42                       <- the original bytes
```

That is the whole chain - bytes, decoder, buffer, encoder, bytes - and it
is what makes the `no-conversion` fallback safe rather than lossy: a file
whose bytes nothing can read goes into the buffer as byte characters and
comes back out as the bytes it was.

All 30 suites pass; `buffer-text-tests.scm` 59 and `coding-tests.scm` 21.

# The coding system a buffer is using (2026-10-06)

Steps 2 and 3 of Chris's plan: `buffer-file-coding-system` holds a real
coding system rather than a line-break convention, and `find-file`,
`insert-file-contents` and `save-buffer` read and write through it. **This
is the change that stopped the two test files being mangled**, and it is
the first time the coding machinery landing over the previous three
commits is called by anything.

## What landed

- **`coding.sld`** — the EOL half, which is what a coding system carries
  beside its codec: `detect-eol` (`coding.c:6374`), `adjust-coding-eol-type`
  (`:6470`), `decode-eol`/`encode-eol`, `as-coding-system`, and the
  variable `*last-coding-system-used*`. Plus `*max-eol-check-count*` and
  `bytes-have-null?`.
- **`files.sld`** — `default-buffer-file-coding-system`,
  `buffer-file-coding-system`/`set!buffer-file-coding-system` over it,
  `coding-system-for-file` (the detect-and-settle step),
  `decode-file-bytes`, `write-file-code-points`, and the three call sites
  rewired. `detect-line-break`, `decode-dos-returns`, `encode-line-breaks`
  and the frame-era `line-break-*` imports are **gone**.
- **`engine.sld`** — `text-editor-insert` takes a *list of code points* as
  well as a string, `text-editor-force-insert-code-point`,
  `text-editor-to-code-points`.
- **`buffer-text.sld`** — `code-point->char`, and `buffer-text-substring`
  goes through it instead of `integer->char`.
- **`xdisp.sld`** — `mode-line-eol-desc` reads `coding-system-eol-type`.
- **`mule.sld`** — the BOM answers `utf-16`, and the local-variables block
  now has Emacs's window and anchors.

## The measurements this was written against

Every rule below was read out of the C or the lisp *and* checked against
Emacs 31.1, and three of the four disagreements found were mine:

| | Emacs | ours, now |
|---|---|---|
| a new buffer's coding system | `utf-8-unix` | same |
| `a\r\nb` decoded as `utf-8-dos` | `(97 10 98)` | same |
| ... as `utf-8-unix` | `(97 13 10 98)` — the CR stays | same |
| ... as `utf-8-mac` (`a\rb`) | `(97 10 98)` | same |
| `a\nb` encoded as `utf-8-dos` | `(97 13 10 98)` | same |
| a CRLF file, no tag | `undecided-dos` | `utf-8-dos` (dep. 1) |
| a CRLF file tagged `utf-8` | `utf-8-dos` | same |
| ... tagged `utf-8-unix` | `utf-8-unix` | same |
| `café naïve` in Latin-1, no tag | `iso-latin-1-unix` | `utf-8-unix` (dep. 2) |
| a UTF-16LE BOM'd file | `utf-16le-with-signature-unix` | `utf-16-unix` (dep. 3) |

**The eol is detected only when the coding system has not named one** —
the C's `(VECTORP (eol_type))` test at `coding.c:8933`. That is why a file
saying `-*- coding: utf-8 -*-` on a CRLF file is `utf-8-dos` and the same
file saying `utf-8-unix` keeps UNIX. Getting this wrong is not visible on
an LF file.

**The eol conversion is a whole-value pass after the codec**, not part of
the character state machine — `decode_eol` runs over what `decode_coding`
produced, and `encode_eol` mirrors it. So the walk in `coding.sld` stays
character-by-character and the EOL half is its own pair of functions.

## Bugs found, each three functions from its symptom

1. **`detect-eol` answered `'lf`/`'crlf`/`'cr` and the caller wanted
   `'unix`/`'dos`/`'mac`.** The C's `adjust_coding_eol_type` is that
   mapping and I left it out, so the name built was `utf-8-lf` — no table
   has it, and the failure surfaced as "Unknown coding system: ?" from
   `coding-setup-port!`, with a `?` where the name should be because the
   value was not a symbol.
2. **`encode-eol`'s DOS branch consed the CR-LF pair in the wrong order.**
   The accumulator is built backwards and reversed at the end, so the LF
   goes on first. Written the readable way round it produces `10 13`, and
   the file is still a file — the round trip test is what caught it.
3. **`find-coding-system` takes a name and `buffer-file-coding-system`
   holds a record.** Emacs has no such split: a coding system there *is* a
   symbol, so `(coding-system-eol-type buffer-file-coding-system)` works.
   The lookup on a record answered `#f`, so **the mode line said `:` for
   every buffer**. Fixed with `as-coding-system`, one coercion in one
   place, which several call sites were already doing by hand.
4. **`files.sld` never imported `text-editor-to-code-points`** — the
   missing-import class, for the sixth time in this tree. It reported as
   `; save-buffer: error writing /tmp/fe-mod.txt` and *the save silently
   did nothing*: `save-buffer`'s `guard` turns any error into an echo-area
   message. The way to see it is to put `(display ex (current-error-port))`
   in the guard's else branch.
5. **`%byte-order-mark` answered `utf-16le`, which keeps the BOM as a
   character.** Read that way the buffer got a U+FEFF in front of the text
   where Emacs's has none — iconv's explicit-order codecs do not strip the
   signature, its plain "UTF-16" does. A latent bug: nothing called the
   function until this pass.
6. **`%local-variables-coding` searched the whole file for the phrase**
   with no line anchor and no `End:` bound, so a file merely *mentioning*
   `Local Variables:` near its top was read as declaring one. Now the last
   3K (`(- size 3072)`), the `[\r\n]PREFIX...SUFFIX[\r\n]` anchors with the
   block's own prefix and suffix, and the block ends at its `End:` line.
   Checked against Emacs on five files, all five matching.
7. **The renderer crashed on a byte character.** Opening the Latin-1 file
   killed the editor: `buffer-text-substring` called `integer->char` on
   `#x3FFFE9`, which is above Guile's `#x10FFFF` *on purpose*. See the
   departure below — this is the one place the port cannot be faithful.

## Departures, and whether to fix them

1. **There is no `undecided` coding system**, so a file that declares
   nothing resolves immediately: Emacs answers `undecided-dos` and we
   answer `utf-8-dos`. Same bytes either way. *Not worth fixing* until
   there is something that consults `undecided` — it exists in Emacs to
   let a later operation re-decide.
2. **The statistical detector (`detect_coding`) is not ported**, so a
   Latin-1 file with no declaration is read as UTF-8 — but the *bytes
   survive*, which is the point: `café naïve` in Latin-1 comes back byte
   for byte, where before this pass it was written back as U+FFFD twice.
   The remaining difference is the *name* Emacs gives the choice
   (`iso-latin-1-unix`) and the fact that Emacs shows `é` where we show
   the eight-bit byte. **Worth fixing, and it is the last big piece**: it
   is `detect_coding` (`coding.c`) and it needs `:charset-list`.
3. **iconv has no "UTF-16LE with signature"**, so both BOMs answer `utf-16`
   and the byte order *written back* is the host's rather than the one
   read. Reading is exact (`utf-16` strips the signature; `utf-16le` keeps
   it as U+FEFF, which is wrong). *Fixable* by adding Emacs's
   `utf-16le-with-signature`/`utf-16be-with-signature` as coding systems
   whose walk writes and strips the BOM itself — worth doing, and small,
   but it is a codec-level BOM step this pass did not have.
4. **A byte character has no character to be.** `buffer-text-substring`
   renders it as U+FFFD where Emacs writes the raw byte to the terminal.
   Nothing that must be lossless goes through it — saving reads with
   `text-editor-to-code-points` — but the *display* of such a file differs
   from Emacs's, and so does the kill ring for a region holding one.
   **Worth fixing** (Emacs's path is `write_glyphs` handing the byte to the
   terminal), and it needs a terminal output path that can write a byte
   rather than a character.
5. **`raw-text`'s EOL conversion is not carried**: both `no-conversion` and
   `raw-text` leave every byte alone, where Emacs converts a CRLF in a
   `raw-text` buffer. The distinction is a third field on the coding
   system, and nothing here asks for one. *Low priority.*
6. **`eval-region`'s and `eval-expression`'s earlier departures stand.**

## Tests

- `coding-tests.scm` 30 (was 21) — `detect-eol` including the
  CR-forgiveness rule (measured: Emacs says `undecided-dos`), the NUL rule,
  `adjust-coding-eol-type`'s only-when-undecided, both EOL directions for
  all three conventions, and `as-coding-system`.
- `ncurses-editor-tests.scm` 239 (was 237) — the round trip: a Latin-1
  file's bytes come back unchanged after a visit and a save, which is what
  used to fail; and the coding system recorded for two files.
- `buffer-text-tests.scm` 61 — the byte-character rendering.
- `tools/pty-check.py` 60 (was 59) — `coding-roundtrip`, which drives `X`
  then `C-x C-s` through the real command loop and compares the bytes on
  disk, and re-checks the CRLF mode line.

## The method note

Reading the C gave every rule here; asking Emacs corrected three of my
expectations and found one bug I had not suspected (the BOM). One of my
own *test* expectations was wrong and the measurement caught it — the
CR-forgiveness case reads `dos` in Emacs and I had written `unix`, then
wrote a case that actually exercises it.

And the paren note: **the reader is the answer, not a hand count.** A
paren-counter written in Python over this file disagreed with Guile for an
hour because it mishandled `#\"` — a character literal whose *name* is a
quote — and so silently started a string at the wrong place. It reported
the pristine file as unbalanced too, which is what should have been the
tell. When the reader and the counter disagree, the counter is wrong.

# The statistical detector (2026-10-06)

Step 4 of the coding plan, and the one that closes the last departure of
substance from the previous pass: **a file that declares nothing is now
read as what its bytes are**, not as UTF-8 by default. `café naïve` in
Latin-1 comes back as `iso-latin-1-unix` with the letters themselves in the
buffer - Emacs 31.1's own answer for the same file - where before it was
`utf-8-unix` with two eight-bit characters in place of the accented ones.

## What landed, and the shape it has

`detect-coding-system` and everything it rests on, in `coding.sld`
(`coding.c`'s own file):

- the **category table** with `coding.c:476`'s enum order, because a mask
  is a bit position and the order has to be the C's;
- `coding-category-list` **as Emacs 31.1 answers it** (measured, not taken
  from the C's default), and `coding-system-priority-list` narrowed to the
  coding systems this tree carries;
- the **three-mask protocol** - `<detection-info>` is the C's
  `struct coding_detection_info` - and `detect_coding_system`'s walk,
  including the branch that stops at `raw_text`;
- `detect_coding_utf_8`, `detect_coding_charset`, and the C's opening
  head-ASCII scan;
- `%finish-detection` is the C's closing `if` chain, which turns the masks
  into coding systems and settles the eol on top.

`files.sld`'s `coding-system-for-file` now asks it when the file declares
nothing, in Emacs's order: declaration first, then detection.

## The measurements it was written against

Every expectation is Emacs 31.1's own answer for the same bytes, by
writing them to a file and asking what `buffer-file-coding-system` became:

| bytes | Emacs | ours |
|---|---|---|
| `hello\n` | `undecided-unix` | undecided ✓ |
| `café` in UTF-8 | `utf-8-unix` | `utf-8-unix` ✓ |
| `café` in Latin-1 | `iso-latin-1-unix` | `iso-latin-1-unix` ✓ |
| `a\xc3(b` (bad UTF-8) | `iso-latin-1-unix` | `iso-latin-1-unix` ✓ |
| `a\xa0b` | `iso-latin-1-unix` | `iso-latin-1-unix` ✓ |
| `a\x85b` (a C1 byte) | `japanese-shift-jis-unix` | `no-conversion-unix` (dep. 1) |
| `a\x9fb` (another) | `emacs-mule-unix` | `no-conversion-unix` (dep. 1) |
| `a\x00b` | `no-conversion` | `no-conversion-unix` ✓ |
| `a\x1b$B$"b` (an escape) | `iso-2022-7bit-unix` | undecided (dep. 1) |
| Latin-1 with CRLF | `iso-latin-1-dos` | `iso-latin-1-dos` ✓ |

## Three bugs, and one of them is the kind that hides

1. **`%reject!` summed where the C ORs.** The masks are bit *sets* and the
   C writes them with `|=`; `+` makes a bit set twice carry into the one
   above. The utf-8 detector's mask *overlaps* the per-category bits the
   walk sets beside it, so carries landed immediately - and the symptom
   was three functions away: `(logand rejected CATEGORY_MASK_ANY) ==
   CATEGORY_MASK_ANY` never held, so a file no detector accepted was not
   reported as `no-conversion`. **`logior`, everywhere.**
2. **The C1 rule lost its upper guard.** In the C the whole test sits
   inside `if (c >= 0x80)`, so `c < 0xA0 && check_latin_extra` means
   0x80-0x9F and nothing else. Written as a bare `(< c #xA0)` it also
   rejects every ASCII control byte - and then **no Latin-1 file is ever
   detected at all**, because every one of them holds a line feed. The
   isolated table above would not have shown it either: the ASCII cases
   pass for a different reason.
3. **`(= c #\return)`** - an integer compared with a character. The tree's
   own hazard note, in the other direction.

## Departures

1. **The detector families this tree does not carry** - ISO-2022, SJIS,
   Big5, CCL, emacs-mule, and `detect_coding_utf_16`. The walk is the C's
   *with those categories unbound*, which is a configuration the C already
   has a branch for (`if (this->id < 0) ... rejected |= 1 << category`), so
   it is the same algorithm rather than a shortcut. The cost is the four
   rows above: a file whose bytes are neither UTF-8 nor valid ISO-8859-1
   is `no-conversion` here where Emacs names a family. **In every one of
   them the bytes survive a round trip, which is the property that
   matters** - and `café` in Latin-1, which is the case that comes up, is
   exact. Worth closing one day for completeness; not worth it for
   behaviour.
2. **`charset.c` is not ported**, so `detect_coding_charset` drives from
   what the tree has rather than from a charset registry: one charset
   family (`iso-8859-1`), whose code space is `0x00-0xFF` at dimension 1,
   and `latin-extra-code-table` as the constant `#f` (which is what this
   Emacs answers for every byte in it - measured). The *algorithm* is the
   C's. A second charset family - `iso-8859-2`, Thai, Devanagari - would
   need the registry.
3. **`undecided` is answered as `#f`**, "the file declares nothing", which
   is what it means to every caller here. Emacs carries it as a coding
   system so a later operation can re-decide.
4. **The encoder's BOM byte order** (from the previous pass) stands.
5. **`detect-coding-region` takes bytes, not a region**, because nothing
   here has a buffer to take one from. Same algorithm, same answers.

## Tests

- `coding-tests.scm` 37 (was 30) - the nine measured files above, plus a
  NUL byte, plus the ASCII-control case that pinpoints the C1 guard.
- `ncurses-editor-tests.scm` 239 - the round-trip test now runs **two**
  files, because there are two routes a byte can take: one the codec
  decodes, and one only the eight-bit representation can carry.
- `tools/pty-check.py` 60/60 - `coding-roundtrip` also asserts the Latin-1
  file *displays* as Latin-1 and not as a placeholder.

## The method note

Reading the C gave the algorithm; the measurements gave three of the
expectations and caught two of the bugs. The third - the `+`-for-`logior`
- was caught by *tracing which rejections happen*, after reasoning about
the masks got me nowhere: a hook that printed each `%reject!` argument
showed `511 1 16384 16 32 262144 ...` and the answer was in the plain
fact that the same bit appeared twice. **When the numbers are masks and
the answer is wrong, print the operations, not the state.**
