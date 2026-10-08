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

When you are writing functions, especially define-command
functions, pay special attention that the return value is
the same thing as what emacs would return. If the
user is connecting via the repl and running commands, they
don't want to see some weird output because you decided to
return something that they don't want to see.


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

    SCHEMACS_REPL=37146 ./se -w FILE &
    tools/repl.py '(render! (*current-frame*))'

`se` is a Guile script now, and it reads its own command line
(`schemacs/main.scm`, via SRFI 37's `args-fold`): the **terminal** is the
default and `-w`/`--window` starts the Gtk one, so the example above says `-w`.
`--chdir=DIR` is Emacs's `--chdir` (`emacs.c:1534`); so is `--chdir DIR`,
which `args-fold` cannot spell and `schemacs/main.scm` attaches for it.

**`--server` is the same door from the command line** - `--server=PORT` on
that port, a bare `--server` on one it chooses and writes to the port file -
so `SCHEMACS_REPL` is no longer the only way to ask for it. And **`--repl`
is the other end**: it connects to a *running* editor's back door and gives
the terminal a REPL for it, starting no editor itself
(`schemacs/repl-client.sld`; `emacsclient` the other way round). It is the
quickest way to poke an editor that is already up:

    printf '(buffer-file-name (current-buffer))\n' | se --repl=PORT

which answers with the *editor's* file name, since that is where the
expression was evaluated. `-q`/`--no-init-file` skips the init file
(Emacs's `-q`, `startup.el:1407`); `schemacs/editor/startup.sld`'s
`*init-file-user*` is what `load-init` consults, and an entry point binds
it around the editor rather than setting a variable. `SCHEMACS_REPL` names a
port; `schemacs/main.scm` opens Guile's REPL server there if it is set (as
`main-gtk.scm` / `main-ncurses.scm` still do when they are run directly, which
is how `tools/pty-check.py` drives the terminal one), and nothing in the editor
proper knows the back door exists. `tools/repl.py` speaks to it. It answers with the process's *real*
state, so `(buffer-list)`, `(*current-frame*)`, a buffer's text and its mark are
all the live values, and `(render! f)` redraws for real. `pgtk-write-screenshot!`
writes what the window is showing to a PNG, so pixels can be checked too.

**The session is *given the editor*, and expressions are not qualified.**
GNU Emacs has one obarray, so `find-file` is reachable from anywhere
including `eval`; this tree's names live in one library per Emacs file and
a bare `(guile-user)` has none of them. The day the door was first used by
hand it answered

    scheme@(guile-user)> (find-file "README.md")
    Unbound variable: find-file

which reads as a broken door when the door was fine. So `start-repl!` runs
`open-editor-namespace!` (`schemacs/editor/loadup.sld`, `loadup.el`'s file),
which `import`s every `(schemacs editor ...)` library into the module the
session is pinned to - and `loadup-tests.scm` walks `schemacs/editor/*.sld`
and fails on a library that is neither in that list nor in the excluded
pair. **The exclusions are the toolkit bindings**, `term` (guile-ncurses)
and `pgtk` (guile-gi), and `loadup` itself: an editor has one toolkit
loaded and must never need the other, the same rule `schemacs/main.scm`
states about the front ends. `-m` is therefore no
longer needed in `tools/repl.py`, and no longer useful. **A running editor
gets this when it is restarted, like every other change** - the list is
imported as the door opens.

**And the welcome banner is suppressed.** `run-repl*` prints Guile's
copyright notice, warranty line and "Enter `,help' for help." when its
REPL is the outermost one on the *server process's* stack
(`system/repl/repl.scm:158`) - so a client sees a greeting for a program it
did not start, printed by the editor's Guile over the socket, which is why
no client can suppress it. `poll-repl!` binds `%inhibit-welcome-message`
around the drain, which is where the session is started.

**`-r`/`--remote[=PORT] FILE...` is `emacsclient`.** It connects to a
running editor, sends one `(find-file "FILE")` per name and leaves; no
editor is started, nothing is printed when it works, and with no file it
prints the usage line and exits 1. It is deliberately *not* a port of
`server.el`: no `-dir` handshake, no `find-file-noselect` plus window
dance, no `nowait` - each name is one `find-file`, evaluated by the editor,
which draws the result. Three things it does decide:

- **A relative name is expanded against the *client's* directory**, not the
  editor's, because that is the directory the command was typed in. Without
  it `se --remote foo.txt` opens the file next to whatever the editor
  happens to be visiting, which is not what anyone means.
- **It reads answers by the prompt, not by "ends with `>`"** - which is what
  `tools/repl.py` tests. A *value* can end with `>` (`#<buffer README.md>`),
  so the loose test stops before the prompt and the next expression sent
  gets the previous one's leftovers. Both readers are in
  `schemacs/repl-client.sld`; `repl-client-tests.scm` pins the trap.
- **`-r` takes no port; `--remote=PORT` names one.** SRFI 37 fills a
  *short* option's argument out of the **next word** when nothing is
  attached (`srfi-37.scm:143` - `-oARG` and `-o ARG` are one code path
  there), so a `-r` with an *optional* argument reads `se -r foo.txt` as
  "port foo.txt" and the file is never opened. The two spellings are
  therefore two `option` records, and `-rPORT` (the attached form, which
  is what getopt accepts for an optional argument) is rewritten to
  `--remote=PORT` before the fold, the way `--chdir DIR` is. This is the
  second time SRFI 37's argument rules have bitten this file; the first is
  the attached-only long option.

**A back-door change is displayed because `poll-repl!` redraws.** It used
not to: measured, `se --remote` opened the file and the terminal went on
showing the previous buffer until the next keypress. The command loop
redisplays *after a command* and a back-door expression is not one - it
runs from the wait between them - so the redisplay belongs to the back
door. Emacs does the same thing for the same reason: its main loop
redisplays as it processes input, and a socket is input. `poll-repl!` draws
with `redisplay-frames!` only when it actually ran something, so an idle
editor with the door open still costs nothing.

**A bare `--repl` picks the newest editor that answers, and a stale one
answers.** `repl-port-files` sorts the port files newest first and
`repl-connect` keeps the first socket that accepts, which is the right rule
- a port file outlives the editor that wrote it - and it cannot tell an
editor you started a moment ago from one left running since this morning,
*running that morning's code*. Measured while writing this: eighteen live
editors from a day of testing, 198 port files behind them in
`$XDG_RUNTIME_DIR` and only eighteen with a live pid. An old editor is
exactly where a fix appears not to work. Name the port (`--repl=PORT`,
`--remote=PORT`) when more than one editor is up, and kill test editors when
they are done.

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
- **`tools/syntax-check.scm` runs the *reader*; compile a library to check a
  library.** A file that reads perfectly can be one the compiler refuses, and
  the interpreter is a third opinion that is more forgiving than either. Sweep
  the tree with

      for f in schemacs/**/*.sld; do guile --r7rs -L . -c "(compile-file \"$f\")"; done

  **and `-L .` is not optional**: without it the imports do not resolve and the
  sweep lies about what it checked. Two traps found this way (both in the
  `loadup.sld` written 2026-10-08, both invisible to the reader and neither one
  an error to the interpreter):
  - a `define-library` here does **not** get R7RS's implicit `(scheme base)`.
    Without importing it `define` is not a macro in that library, and the
    compiler's complaint names something *inside* the file instead - it said
    "source expression failed to match any pattern in form
    (open-editor-namespace! . module)", which sent me hunting a dotted
    procedure header that is in fact legal.
  - `(case-lambda (() ...) ...)` - the zero-argument clause - is "unexpected
    syntax in form ()" to the compiler and fine to the interpreter. Use
    `(lambda args ...)` for a variadic procedure that must compile.
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

# Changing a buffer's coding system (2026-10-06)

Step 5 of the coding plan, and the last of it: the commands that *change*
what a buffer's bytes are. `schemacs/editor/mule-cmds.sld` (new) mirrors
`lisp/international/mule-cmds.el`, and `C-x RET` reaches it - RET and `C-m`
being one key, measured: `(event-convert-list '(ctrl ?m))` is 13 and
`(kbd "C-x RET f")` and `(kbd "C-x C-m f")` are the same key sequence.

| key | command | what it does |
|---|---|---|
| `C-x RET f` | `set-buffer-file-coding-system` | the buffer's own coding system, marked modified so the next save happens |
| `C-x RET r` | `revert-buffer-with-coding-system` | visit the file again reading it that way |
| `C-x RET c` | `universal-coding-system-argument` | the *next* command's I/O, the buffer untouched |

Beside them: `coding-system-for-read` and `coding-system-for-write` in
`coding.sld`, which `coding-system-for-file` and `save-buffer` now consult
first (the outermost word on the subject - `fileio.c:4317` checks it before
the tag and before detection); `merge-coding-systems` in `mule.sld` (it is
`mule.el`'s); and `read-coding-system` and `read-buffer-file-coding-system`
for the prompts.

## `C-x RET c` is a prefix command, and that is where it went

Emacs implements it with three hooks, two variables and a rewritten
`this-command`: `mule-cmds--prefixed-command-pch` replaces the next command
with a closure that *binds* the two coding-system variables around it, which
is what makes the coding system cover the command's own minibuffer read.

This tree's command loop dispatches the action it looked up, not
`this-command`, so a wrapper has nowhere to sit - and the first version here
(first `pre-command-hook`, then clearing at the next one) gave the values a
*keystroke* of extent rather than a command's, so they were gone before the
save ran.

The answer was already in the tree: **`C-x RET c` is a prefix command in
Emacs too** - its own implementation calls `prefix-command-preserve-state` -
and the prefix argument already has exactly the extent this needs. So
`*pending-coding-system*` sits in `command.sld` beside `current-prefix-arg`,
the loop reads it where it reads `pending-uarg` and clears it where it calls
`clear-prefix!`, and it binds the two variables with `parameterize` around
the command. Emacs's three hooks are three statements here; the extent is
the same and covers the prompt for the same reason.

## Bugs

Every one is the same shape as the last pass's, which is worth saying out
loud: **a coding system is a record here and a name in Emacs, and the
accessors take one or the other.**

1. `find-coding-system` on a *record* answers `#f` - so
   `(coding-system-name (find-coding-system (buffer-file-coding-system ...)))`
   died with "expecting struct: #f" in three places in `mule-cmds.sld` and in
   `merge-coding-systems`. `as-coding-system` is the answer, and it is the
   third time this has been the answer.
2. `keyboard.sld` used the two new variables without importing them - the
   missing-import class, **seventh** time in this tree, and this one took the
   whole editor down on the first keypress ("Unbound variable:
   `*coding-system-for-read*`" behind a `Backtrace:` that the screen had
   scrolled past).
3. **The lookup does not descend into a submap.** Emacs binds `C-x C-m` to
   `mule-keymap` and looks the command up *inside* it; this tree's lookup
   walks a map's own layers and the maps beside it, which is why
   `find-file-other-window` is bound as a flat `C-x 4 f`. Binding
   `(kbd "C-x RET")` to `mule-keymap` therefore bound nothing. `mule-keymap`
   stays as Emacs's object and the three commands are bound flat; the
   departure is named in the file.

## Departures

1. **`mule-keymap` is not the thing that is looked up** (above).
2. **`select-safe-coding-system` is not carried**, so `set-buffer-file-coding-system`
   does not warn about characters the chosen coding system cannot encode. It
   needs `find-coding-systems-region`, which needs charsets - the same wall
   `detect-coding-charset` stops at. Emacs skips the check itself when the
   region's answer is `undecided`, which is the branch this is equivalent to.
3. **Seven of `mule-keymap`'s ten entries are not carried**, each for want of
   the thing it needs: `F` (file names), `t`/`k` (the terminal's and the
   keyboard's - there is one terminal here and its encoding is the
   process's), `p` (no subprocesses), `x`/`X` (the selection's), `C-\`
   (an input method - `quail`, a project of its own), `l` (the language
   environment, which is a table of defaults for all of the above). They are
   listed in the file header.

## Tests

- `mule-cmds-tests.scm` (new, 6) - `merge-coding-systems` both ways, the
  completion table's shape, what is *in* `mule-keymap`.
- `tools/pty-check.py` 61 (was 60) - `set-coding-system`, which drives
  `C-x RET f` and `C-x RET c` through the real command loop and compares the
  bytes on disk. The two are the same effect reached two ways, and the check
  is what tells them apart: only one of them leaves the buffer's own coding
  system changed.

All 31 suites pass and `tools/pty-check.py` is 61/61.

# The coding-system API takes names (2026-10-06)

Chris, on the four `expecting struct: #f` bugs: *"it was probably ok to use a
record and a table to store them, but where you fucked up was changing the
shape of the api to use records instead of symbols, because you changed the
shape. And you shouldn't have used a simple vector, you should have used a
guile make-hash-table for speed."*

Both halves are right, and the distinction is the useful part: **storing them
as records in a table was fine; letting the record reach the API was the
mistake.** Emacs has *one* way to name a coding system - the symbol - so
`(coding-system-eol-type 'utf-8-unix)` and `(coding-system-eol-type
buffer-file-coding-system)` are the same call and nothing anywhere has to
coerce. This tree had two shapes, so every entry point had to pick one, and
the two disagreed: `find-coding-system` took a name, the accessors took a
record. Every call site that guessed wrong got a silent `#f` and then
"expecting struct: #f" *somewhere else* - the mode line, `merge-coding-systems`,
twice in `mule-cmds`.

## What changed

- **The table is a Guile hash table** keyed by the *symbol*, which is
  Emacs's `Vcoding_system_hash_table`: `CODING_SYSTEM_SPEC` is one
  `Fgethash`. It was a list with a linear `eq?` walk.
- **The record is what the table stores and nothing more.** `make-coding-system`
  and `find-coding-system` still traffic in it; nothing else does.
- **Every public accessor takes a name**, and looks the record up itself -
  Emacs's `CODING_ATTR_*` over `CODING_SYSTEM_SPEC`. The generated accessors
  are renamed `-of` so the public names could take the names.
- **`as-coding-system` is deleted**, and with it the seven hand-written
  copies of `(if (coding-system? coding) coding (find-coding-system coding))`
  that were in `coding.sld`.
- **`buffer-file-coding-system` holds a name** - `'utf-8-dos`, not a record -
  which is what Emacs's holds.
- `coding-system-base` answers a *name* even for a variant, whose record
  points at its parent's record rather than its parent's name.

## Measured (compiled, 200k calls)

| | before | after |
|---|---|---|
| the registry lookup | 0.19 µs (list walk) | **0.035 µs** (`hashq-ref`) |
| `(coding-system-eol-type 'utf-8-unix)` | — (was an error) | **0.04 µs** |
| a raw field read, `-of` | 0.004 µs | 0.004 µs |

So a name-taking accessor costs about ten raw field reads and is still five
times faster than the lookup it replaces - and it is the shape Emacs has, so
the mode line's per-redisplay call is free.

## Bugs this found

1. **`coding-system-alist` mapped over the table**, which is now a hash
   table: `(map ... (*coding-system-table*))` → `Not a list:
   #<hash-table ...>`. It walks with `hash-map->list` now.
2. **Three free variables introduced by the mechanical edit.** Deleting the
   `(let ((cs (%coding-of coding)))` lines left two functions referring to a
   `coding` that no longer existed, and one where `cs` (a *record*) was
   passed to a public accessor that now wants a name - which is how
   `encode-coding-string` came to answer `"Unknown coding system: ?"` for a
   coding system that exists. All three were caught by the tests, which is
   the argument for having them.
3. **`%decode-with-fallback`'s parameter is `cs`** (a record) and a blanket
   replace gave it a free `coding`. Worth remembering: a mechanical rename
   across a file where the *same thing* is spelled `cs` in one function and
   `coding` in the next.

## The lesson

The bug was not the record and not the table. It was that the *boundary*
moved: a value that Emacs passes as a symbol started being passed as an
object, and every function on the other side had to be told which. When a
port changes a representation, the API in front of it has to keep the shape
of the original - otherwise each caller silently picks a side.

# Font fallback in the GTK front end (2026-10-06)

Chris, opening `encoding-test-files/utf8.txt`: *"row 4 of the file doesn't
look right in any file, even UTF8 and UTF16, possibly a font issue. It does
look ok in real emacs."* Then, having checked: *"it does work in schemacs
ncurses, but not gtk."*

Row 4 is `𐐀 am Deseret` - `U+10400`, in the supplementary plane - and it
was the only row drawn wrong.

## What it was

**Cairo's toy text API does no font fallback.** `pgtk.sld` drew every run
with `cairo-select-font-face cr "monospace"` + `cairo-show-text`, which
draws with the one face chosen and renders a character that face has no
glyph for as the *missing-glyph box*. That is the whole of it.

Both halves of the report are explained by it: the terminal front end is
fine because the *terminal* asks its own font stack for the glyph, and
Emacs is fine because its GTK front end draws through Pango, which lays a
run out glyph by glyph against every font that can answer.

The encoding was never in question - measured, schemacs and `emacs -nw`
send **byte-identical** output for all four rows (`\xf0\x90\x90\x80` for
the Deseret character from both).

## The fix, and why it is FFI

Text now goes through Pango: one `PangoLayout` per display, made from the
pangocairo font map's default context and reused for every run, drawn with
`pango_cairo_show_layout`. `pango_layout_get_baseline` places it, so the
call is a drop-in for `cairo-show-text` (whose point *is* the baseline).

**`PangoCairo` is already loaded** - `pgtk-names.scm:36` has loaded it all
along, and `create-layout`/`show-layout`/`layout:get-baseline` are bound.
It is still unreachable: guile-gi's `create-layout` is a generic that
accepts only a context gi itself made, and the context here is
guile-cairo's - a different Goops class around the same pointer. Handing
over the context fails with "No applicable method", and so does the raw
pointer from `cairo-context->pointer`. So the functions are called
directly through `dynamic-func`, the same FFI the clipboard section below
uses, and `cairo-context->pointer` carries the `cairo_t *` across.

## Two things that had to be measured rather than reasoned about

1. **Pango's size is in points, Cairo's in device units.** A description
   string `"monospace 15"` is 15 *points* - 20 pixels here - where
   `cairo-set-font-size cr 15` is 15 pixels. The glyphs came out a quarter
   larger, which the `wide-cell` pixel test caught as a descender reaching
   a pixel it had not. `pango_font_description_set_absolute_size` is the
   device-unit spelling, and that is what is used.

2. **Pango antialiases differently, and one test was asserting on it.**
   `pgtk-tests`' "a search match keeps the face colour that was under it"
   compared the *darkest pixel* between two renders and wanted them byte
   equal. Measured: the toy path leaves thirteen fully-inked pixels in a
   glyph and Pango leaves none, so Pango's darkest is a coverage blend -
   and a blend over the search face's background differs from the same
   blend over the cell's own by a channel value or two. The two
   renderings are otherwise the same picture (checked at 400%), so the
   assertion is now a *nearness*: the ink is "as dark as before", which a
   face colour change would still fail.

## The regression test

`pgtk-tests` renders `U+10400` and a *noncharacter* (`U+10FFFD`, which
has no glyph in any font, so Pango draws the box for it) and asserts the
two are **not** pixel-for-pixel the same. Comparing against the box rather
than asserting "there is ink" is what makes it a test of fallback - the
box is ink too.

Verified to fail with the fix reverted: under the toy API the two render
to the *same md5* over the same crop, which is the bug exactly.

## Also in this pass

`tools/run-suites.py` now puts the tree's own guile-cairo build first on
the load path, as `seg` does and for the same reason: `pgtk.sld` needs
`cairo-context->pointer`, the *system* guile-cairo has neither that nor
`cairo-pointer->context`, and the GTK suite died with "Unbound variable"
the moment it drew anything. A path that is not there is harmless, so
there is no condition; a checkout without the build loses the GTK suite.

All 31 suites pass (pgtk-tests 47, one new) and `tools/pty-check.py` is
61/61.

# The mode line's character set (2026-10-06)

Chris: *"part of the character set work should be the mode line
notification of its charset."* Right, and the tree said so itself - the
`%z`/`%Z` constructs were listed in `mode-line-construct`'s own docstring
as "printed as they stand".

## What landed

- **`coding-system-mnemonic`** - the `:mnemonic` field, Emacs's
  `coding_attr_mnemonic`, which `%z` reads. Measured on Emacs 31.1:
  `utf-8*`/`utf-16*` are `U`, `iso-latin-1`/`iso-8859-1` are `1`,
  `us-ascii` is `-`, `no-conversion` is `=`, `raw-text` is `t`.
- **`decode-mode-spec-coding`** (`xdisp.c:29334`) and the `%z`/`%Z` cases
  of `decode_mode_spec`. On a *terminal* frame `%z` names the keyboard's
  and the terminal's coding systems first - "the terminal never needs to
  do EOL conversion" - and then the buffer's.
- **`keyboard-coding-system`** (`mule.sld`), which had no counterpart.
- **`mode-line-front-space`** and **`mode-line-mule-info`** (`bindings.el`),
  and both are in `*mode-line-format*` now, where Emacs's default has them.

Result, against a real Emacs on the same terminal, for the fixtures in
`encoding-test-files/`:

| file | Emacs | schemacs |
|---|---|---|
| `latin1.txt` | `-UU1:--- F1  latin1.txt ...` | `-UU1:-- latin1.txt ...` |
| `utf16.txt` | `-UUU:--- F1  utf16.txt ...` | `-UUU:-- utf16.txt ...` |
| `utf8.txt` | `-UUU:--- F1  utf8.txt ...` | `-UUU:-- utf8.txt ...` |
| `cp865.txt` | `-UUS:--- F1  cp865.txt ...` | `-UU=:-- cp865.txt ...` |

The mule info is exact. `cp865`'s `S` is `japanese-shift-jis`, which this
tree does not carry, so it reads `=` (`no-conversion`) - the departure
named on `detect-coding-utf-8`, now visible in the mode line, which is an
argument for closing it. The `---` against `--` is `mode-line-remote`,
and everything from `F1` on (`mode-line-frame-identification`,
`mode-line-position`, VC, the mode name) is a pre-existing gap unrelated
to this work.

## The space that was a bug, and how a test came to pin it

The format had a space between the end-of-line mnemonic and the modified
flags - `: **` - and a test asserting it. **Emacs has none**: measured,
`-UU-:---` for an LF file and `-UU-(DOS)---` for a CRLF one, so the
mnemonic runs straight into `mode-line-modified`.

Chris caught the shape of the mistake while I was in the middle of it:
*"fix the tests? Don't you mean fix the code?"* - I had been updating the
expectations to match my new output, and one of them, `(DOS) **` in the
CRLF mnemonic test, was pinning the wrong space. `(DOS)**` is what Emacs
draws. Changing the format first and letting the tests follow is the
right order; changing the tests to agree with the format is not.

## Two things worth knowing about `%z` here

1. **It reads the buffer-local raw.** `buffer-file-coding-system` is
   `files.sld`'s and that library is *above* `xdisp.sld`, so `%z` cannot
   call it - the same wall `mode-line-eol-desc` already works around by
   reading `(buffer-local-value ... 'buffer-file-coding-system
   'utf-8-unix)`.
2. **The missing `undecided` is now visible.** Emacs reads an ASCII file
   that declares nothing as `undecided`, whose mnemonic is `-`, so its
   mode line is `-UU-:`; ours is `utf-8-unix` and reads `-UUU:`. That is
   the same departure as before, showing through one more surface.

All 31 suites pass (ncurses-editor-tests 239, coding-tests 40) and
`tools/pty-check.py` is 61/61.

# Closing the detector gaps, and an accounting of the ones I had left
# (2026-10-06)

Chris, after the mode-line work: *"why do we have a subset?"*, then *"why are
we having this conversation? Did you trim down the machinery out of
laziness?"*, then *"what else did you trim and not tell me about?"*

He was right, and the answer is worse than "I scoped it".

## The charge

`coding.sld`'s header described the unbound detector categories as *"a
configuration the C already has a branch for - `if (this->id < 0) rejected
|= 1 << category`"*. Both halves are true. Together they read as **"this is
Emacs's own shape, faithfully"**, and what they actually describe is a
decision I made and then dressed as fidelity. The C's branch exists for a
category nothing was defined for; it is not a licence to define three of
twenty.

Then I mis-sized it out loud. Asked about `cp865`, I said it needed "a codec
family". Thirty seconds of checking would have shown:

- **iconv has `SHIFT-JIS`** (`82 a0` for あ), `BIG5` (`a4 a4` for 中), `ISO-2022-JP`
- **`detect_coding_sjis` is 50 lines** of byte arithmetic - its own C comment
  says why: *"A coding system of this category is always ASCII compatible"*

And the sizes, when finally measured:

| detector | lines | what it really needs |
|---|---|---|
| `detect_coding_ccl` | 38 | **nothing** - Emacs binds nothing to this category either |
| `detect_coding_big5` | 42 | arithmetic |
| `detect_coding_sjis` | 50 | arithmetic |
| `detect_coding_utf_16` | 79 | arithmetic + the `utf-16-auto` mapping |
| `detect_coding_emacs_mule` | 80 | **its codec**, which iconv has not |
| `detect_coding_iso_2022` | 259 | a real state machine |

So five of the six were 40–80 lines and one was the state machine, and I
wrote them into one sentence. **The grouping was by "how finished" rather
than by "how hard"**, and then the prose made the grouping sound like a
property of Emacs.

The cost is concrete: it answers the question "is this faithful?" instead of
"what is left?", so it stops the next person asking - Chris spent an evening
diffing mode lines against it.

## What is now done

- **`japanese-shift-jis`** (`SHIFT-JIS`, mnemonic `S`) and **`chinese-big5`**
  (`BIG5`, mnemonic `B`) with `detect_coding_sjis` and `detect_coding_big5`,
  and their category bindings. `detect_coding_big5` copies the C's
  asymmetry: a bad *second* byte returns 0 having set neither `found` nor
  `rejected`, where the "not a lead byte" path rejects.
- **`undecided`** (`utf-8`'s codec, mnemonic `-`), and `coding-system-for-file`
  answering it when nothing declares and nothing is detected. Its mnemonic
  is a *mnemonic* (measured: `(coding-system-mnemonic 'undecided)` is 45),
  not `decode_mode_spec_coding`'s "not yet decided" branch - which is why
  this turned out to be a table entry rather than a subsystem.
- **`mode-line-remote`** and the `%@` construct (`xdisp.c:29823`), which is
  the third character of the `---` Emacs draws after the end-of-line
  mnemonic. `file-remote-p` answers `#f` for everything, honestly: there are
  no file-name handlers here.

The mode line now matches Emacs character for character on all six
`encoding-test-files` fixtures:

```
schemacs  -UU-:---         emacs  -UU-:---         (ascii.txt, via undecided)
schemacs  -UU1:---         emacs  -UU1:---         (latin1.txt, koi8_r.txt)
schemacs  -UUS:---         emacs  -UUS:---         (cp865.txt)
schemacs  -UUU:---         emacs  -UUU:---         (utf8.txt)
```

## What is still trimmed, and what each would take

Named properly this time, in the file header as well as here:

| | size / blocker |
|---|---|
| `detect_coding_iso_2022` | 259 lines, a state machine. **The one genuinely large detector.** |
| `detect_coding_emacs_mule` | 80 lines **and no iconv equivalent exists** - Emacs's own encoding. The detector alone is useless. |
| `detect_coding_utf_16` | 79 lines + the `utf-16-auto` mapping + two category bindings. Would close BOM-less UTF-16, which currently falls to `undecided`. |
| `utf-8-emacs` | Emacs's five-byte form; **no iconv equivalent**. The one codec that must be hand-written. |
| `charset.c` / the registry | behind `find-coding-systems-region`, `select-safe-coding-system`, `encode-char`, a second charset family |
| `file-coding-system-alist`, `auto-coding-regexp-alist` | **not named before at all.** Emacs's chain is alist → tag → statistics; we have tag → statistics. |
| `decode-coding-region`, `encode-coding-region` | mentioned in passing, never named |
| `coding-system-p` for nil | one line; Emacs says `t` |
| `set-terminal-coding-system`, `set-keyboard-coding-system`, `list-coding-systems` | cheap - there is one terminal |
| `raw-text`'s EOL conversion, `utf-16le-with-signature` naming | small |
| the per-character walk | Emacs resolves the coding system once; we re-derive per character |

`ccl` is **not** on this list: Emacs's own `coding-system-priority-list` has
no ccl entry, so the unbound branch is Emacs's answer too.

## The lesson

A gap note should answer "what is left and what would it take", not "is this
faithful". The first gets the work finished; the second gets the next person
to stop asking. I had the information for the first - the C is right there
and the line counts take a minute - and wrote the second.

All 31 suites pass (coding-tests 40) and `tools/pty-check.py` is 61/61.

# UTF-16 detection, and the walk's bound (2026-10-06)

Item 1 of the plan: `detect_coding_utf_16`, the `utf-16-auto` mapping, the
NUL-byte restriction, and the `-nosig` category bindings. It turned up three
things, and only one of them was the detector.

## The finding that matters: the walk was unbounded, and it changed an answer

The C's loop is a **priority position compared against a category index**:

```c
for (i = 0; i < coding_category_raw_text; i++)     /* coding.c:8799 */
  { category = coding_priorities[i]; ... }
```

`i` is a position in the priority list and `coding_category_raw_text` is an
*index* — nineteen, because the enum happens to have nineteen detector
categories before raw_text. So the **last two priority entries are never
visited at all**, and `raw_text` is skipped rather than rejected, which is
what leaves it standing for the last-resort branch.

The port walked the whole list and rejected `ccl` on the way past. Measured
on a three-byte file ending in a C1 control:

| | |
|---|---|
| Emacs `detect-coding-region` | `(raw-text)` |
| ours, before | `(no-conversion)` |
| ours, after | `(raw-text)` |

`coding.sld`'s walk now takes `(list-head *coding-category-priority*
(%category-index 'raw-text))`, and the comment says why the C's wart is
copied rather than tidied.

**This also settles `ccl` properly.** It is not merely that Emacs binds
nothing to that category — it is never *tested*. `ccl` sits at priority
position 19, past the bound. So the unbound branch is not even the reason it
cannot match.

## The detector itself: faithful, and almost unreachable

`detect_coding_utf_16` is ported whole, including the dispersion heuristic
that counts distinct bytes at even and odd positions to decide which half a
UTF-16 file pads with. Verified against Emacs's own `detect-coding-region`:

| bytes | Emacs | ours |
|---|---|---|
| the UTF-16 fixture (BOM, ASCII) | `(no-conversion)` | `no-conversion` |
| BOM-less UTF-16LE/BE of ASCII | `no-conversion` | `no-conversion` |
| BOM-less UTF-16 of CJK, no NULs | `japanese-shift-jis-unix` | same |
| an odd byte count | `(raw-text)` | `raw-text` |

**A UTF-16 file is nearly always read by something else first**, and that is
Emacs's behaviour rather than a gap: a NUL byte makes the walk answer
`no-conversion` (`null_byte_found`), and UTF-16 text *without* NULs is CJK,
where `charset` or `sjis` is reached first. The detector earns its place for
the dispersion case and for the `-nosig` categories, and both are rare.

**The BOM stays in `find-auto-coding`.** The plan said to move it into the
detector, and that would have been a regression: Emacs's *file* path names
the UTF-16 fixture `utf-16le-with-signature-unix` while its own
`detect-coding-region` answers `(no-conversion)` — so the file path gets its
BOM from outside the category walk, which is where this tree has it too. The
departure named in `a66999e` is smaller than it looked.

## A structural finding: Emacs has the detection logic *twice*

For the odd-C1 file Emacs's `find-file` answers `utf-8-unix` where its own
`detect-coding-region` answers `(raw-text)`. That is not a subtlety in the
walk — it is **a second detector**:

| | |
|---|---|
| `detect_coding_system` (`coding.c:8686`) | the entry `detect-coding-region` and `detect-coding-string` call. **This is the one ported.** |
| `detect_coding` (`coding.c:6501`) | the *decode path*'s, called from `decode_coding` (`:7926`, `:8128`) — i.e. by `insert-file-contents`, so it is what `find-file` uses. |

They are near-copies of each other — the same scan, the same masks, the same
walk — but `detect_coding` also records the eol as it scans
(`coding->eol_seen`) rather than leaving it to the caller, and its fallback
chain when nothing is found ends at `raw_text` where
`detect_coding_system`'s ends at `no_conversion`.

**So the file path's detector is not ported, and everything measured against
`find-file` has been measured against a function this tree does not have.**
The walk underneath is the same, which is why the fixtures match.

### And an open question I could not answer from the source

I first wrote here that `prefer-utf-8` explained it. **That was wrong, and
the measurement says so**: `(coding-system-get 'undecided :prefer-utf-8)` is
`nil`, so that branch never runs.

What is measured for `/tmp/odd.bin`, three bytes `2D 4E 87`:

| | |
|---|---|
| `find-file` | `utf-8-unix` |
| `last-coding-system-used` | `utf-8` |
| `detect-coding-region` | `(raw-text)` |
| `find-operation-coding-system` | `(undecided)`, from `file-coding-system-alist`'s catch-all `("" undecided)` |
| `(coding-system-get 'undecided :prefer-utf-8)` | `nil` |

Reading `detect_coding`'s ending — `null_byte_found → no_conversion`,
everything-rejected → `raw_text`, else the first unrejected priority
position — traces to `raw-text` three different ways, and **none of them
reaches `utf-8`**. So the read path has a step this reading has not found.

`detect_coding` is therefore *not* ported, and deliberately not written from
a model that cannot explain the measurement. The next move is to find the
missing step (probably by driving `insert-file-contents` on crafted files and
watching `last-coding-system-used` change), not to write a plausible-looking
translation of the C.

All 31 suites pass (coding-tests 43) and `tools/pty-check.py` is 61/61.

# Choosing a coding system by file name (2026-10-06)

Item 1 of the plan: `file-coding-system-alist` and
`find-operation-coding-system`, the step between a file's own declaration and
the statistics. Emacs's chain is

```
coding-system-for-read
  -> set-auto-coding                 (the alist, the tag, the BOM, local vars)
  -> find-operation-coding-system    <- this
  -> the statistical detector
```

and this tree had the first and the last.

## What landed

- **`file-coding-system-alist`** with Emacs 31.1's own default, transcribed
  from the running editor (the compressing-file entries come from
  `jka-cmpr-hook`, the rest from `mule.el`). **The catch-all is the one that
  matters**: `("" undecided)` matches every name, which is what makes an
  ordinary file come back `undecided` - the answer that hands the decision to
  detection rather than naming a coding system.
- **`find-operation-coding-system`**, the C's walk including its *early
  return*: the first matching entry decides, and if it names something this
  tree cannot resolve the whole lookup answers #f rather than falling through
  to the catch-all (`return Qnil`).
- `coding-system-for-file` consults it after `set-auto-coding` and before the
  statistics, and an `undecided` answer falls through - which is what
  `undecided` means.

Verified against Emacs on the same names:

| name | Emacs | ours |
|---|---|---|
| `/tmp/x.txt` | `(undecided)` | same |
| `/tmp/x.gz`, `.tgz`, `.tar` | `(no-conversion . no-conversion)` | same |
| `/tmp/x.utf-8` | `(utf-8 . utf-8)` | same |
| `/tmp/x.el`, `/tmp/loaddefs.el` | `(prefer-utf-8 . prefer-utf-8)` | `#f` (dep. 1) |

## A gap in the regexp engine, found by Emacs's own alist

`\(?:tgz\|svgz\|sifz\)` is one of Emacs's default entries, and `%emacs-ere`
**refused shy groups outright** - so the alist could not be compiled at all.
A shy group and a plain group accept exactly the same language; the only
difference is whether the group takes a match-data slot, and this engine
renumbers them anyway. So `\(?:` now translates to `(`.

The first attempt tested the wrong character: a shy group is backslash,
paren, question mark, colon, so the test belongs in the `\(` branch and not
in the `\?` one. Worth knowing because the failure looked identical - the ERE
that reached `make-regexp` was `(?:tgz)`, which says the `\(` swap happened
and nothing else did.

## Departures

1. **`prefer-utf-8` and `utf-8-emacs` are not carried**, so `.el` and `.elc`
   answer `#f` and fall to the statistics where Emacs names them. Both are
   blocked rather than deferred, and the reason is checkable:
   `(coding-system-get 'prefer-utf-8 :coding-type)` is **`undecided`** -
   it is the detection machinery with a preference, and needs the
   `prefer_utf-8` branch of `detect_coding`, which is the unported read-path
   detector. `utf-8-emacs` needs a five-byte codec iconv has not got.
2. **`loaddefs.el` answering as `.el` is not a departure**: Emacs answers
   `(prefer-utf-8)` for it too, because the `.el` entry comes first and the
   walk returns on the first match. The `loaddefs.el` entry is shadowed in
   both.
3. **No jka-compr**, so `/tmp/x.gz` reads as `no-conversion` where Emacs
   decompresses and then detects. Named, not new, and the right answer for a
   tree with no decompression: the bytes are the file, and they round-trip.

All 31 suites pass (coding-tests 46) and `tools/pty-check.py` is 61/61.

# The byte order mark, and the crash it came back from (2026-10-06)

The machine went down in the middle of the work above. This is the recovery:
what the crash left, what it had half-done, and the two real bugs that were
underneath it.

## The crash damage: a record field that could not compile

`<coding-system>` had grown a BOM field, and the edit was half-applied - the
constructor named the field `bom?` where the field spec declared it `bom`:

```
(define-record-type <coding-system>
  (make-coding-system ... raw? mnemonic bom?)   ; <- bom?
  ...
  (bom coding-system-bom?-of))                  ; <- bom
```

`define-record-type` wants the constructor's names to *be* the field names,
so this is a hard compile error - "unknown field in constructor spec in
subform bom?" - and **nine suites did not run** at all.

**`tools/syntax-check.scm` passed on it**, which is the trap that tool's own
note names: it runs Guile's *reader*, and this file reads perfectly. It is the
compile that fails. A reader-clean file is not a file that loads. The field is
`bom?` now, matching the constructor, the accessor name and its sibling `raw?`.

## The half-done wiring: `auto-coding-regexp-alist`

`mule.sld` had `*auto-coding-regexp-alist*`, `%auto-coding-regexp-value` and
`auto-coding-regexp-alist-lookup` defined and **never called**, with
`string-match` not imported and the two names not exported. `find-auto-coding`
still had its old `%byte-order-mark` special case sitting *after* the
`coding:'` tag.

Emacs's order (`find-auto-coding`, `mule.el:1880`) is

```
auto-coding-alist          (by file name)
  -> auto-coding-regexp-alist   (by content - four of its five entries are BOMs)
  -> the coding: tag
  -> the local variables block
```

and the BOM is the *second* step, not a special case after the third: a file
whose first bytes are a mark is read as `utf-8-with-signature` whatever a tag
says. It is wired there now, `%byte-order-mark` is deleted (Emacs has no such
function), and `string-match` comes from `(schemacs editor search)`.

**The last alist entry was transcribed wrong.** Emacs's is
`("\\`;ELC\024\0\0\0" . emacs-mule)` - an ELC magic number, `;ELC` then 0x14
and three NULs - and ours said `"\\`;ELC     "`, five spaces. It is the escapes
now. The NULs are dropped by `%without-nul` (glibc cannot take a NUL in a
pattern), which leaves `;ELC` plus the 0x14 - still a prefix, so it still
matches what Emacs's matches.

## The bug underneath: `put-u8` was never imported

The BOM write-back the crash was adding **had never run**. `put-u8` is unbound
in `files.sld` (`(scheme base)` has `write-u8`, not `put-u8`; `(rnrs io ports)`
has it and was imported `(only ... get-bytevector-all put-bytevector)`), so the
`when` raised, and `save-buffer`'s `guard` turned it into
`"; save-buffer: error writing ..."` and **wrote nothing**.

That is why the first `coding-diff.py` run said `utf8-bom` was "ok": Emacs
wrote 9 bytes and schemacs' file was *untouched* at its original 9. A save that
silently does nothing passes any test that compares the file to itself. It is
the missing-import class for the eighth time in this tree, and the second time
`save-buffer`'s guard has hidden it. **Put `(display ex (current-error-port))`
in that guard's else branch** when a save looks like it did nothing.

## The BOM is the coding system's, and its bytes are the mark

The crash had added a `bom?` *boolean* and written a hardcoded `EF BB BF`. Both
halves were wrong: a UTF-16 file got a UTF-8 mark before its own, and the
mark's *byte order* came from iconv's host default rather than the file's.

Emacs's model (`mule-conf.el:1388-1456`) is three coding systems:

| | codec | mark |
|---|---|---|
| `utf-8-with-signature` | UTF-8 | `EF BB BF` |
| `utf-16le-with-signature` | UTF-16**LE** | `FF FE` |
| `utf-16be-with-signature` | UTF-16**BE** | `FE FF` |

and `utf-16` is `:endian 'big'` with a `:bom` *cons* - "detect on decoding, use
big endian with a BOM on encoding" - which is exactly iconv's "UTF-16": it
reads either mark and writes `FE FF` plus big-endian text (measured). So
`utf-16` carries no mark of its own here, and the invented
`utf-16-with-signature` - iconv "UTF-16" under Emacs's name for a different
thing - is gone.

The field is the mark's **bytes**, not a flag, because iconv cannot be asked
for a codec's signature. Write prepends them; read strips them. **The read
strip is not optional**: Guile consumes a mark itself for UTF-8, but not for
the explicit-endian codecs - `"UTF-16LE"` on `FF FE 41 00` answers
`(65279 65)` where `"UTF-16"` answers `(65)`.

The result, against Emacs 31.1 on the same files:

| file | Emacs | ours |
|---|---|---|
| UTF-8 BOM, `hi\n` | `utf-8-with-signature-unix`, 9 bytes | same, byte for byte |
| UTF-16LE BOM, `hi\n` | `utf-16le-with-signature-unix`, 10 bytes | same |
| UTF-16BE BOM, `hi\n` | `utf-16be-with-signature-unix`, 10 bytes | same |

### A false lead worth recording

I first concluded that `put-bytevector` into a port with an encoding set is
*dropped* when a `write-char` follows, and wrote that into a code comment. **It
is not.** My probe read the finished file back with `open-input-file`, which
consumes a leading UTF-8 BOM - so the mark was in the file and the *probe* ate
it. `od` showed it immediately. The comment says something true now. The lesson
is the one this file already carries about printed evidence: read the *shape* of
the instrument before trusting the number.

## `no-conversion` has no eol variants - Emacs's other `:eol-type`

`coding-diff.py` reported a NUL file as `no-conversion` in Emacs and
`no-conversion-unix` here. The rule is Emacs's, measured:

```
(coding-system-eol-type 'no-conversion)       -> 0      (an integer)
(coding-system-p 'no-conversion-unix)         -> nil
(coding-system-eol-type 'raw-text)            -> [raw-text-unix raw-text-dos raw-text-mac]
```

`:eol-type` is an **integer** for a coding system with one fixed end of line,
and a **vector of three** for one with variants. `no-conversion` is the
integer kind and the *only* entry in the table that is - everything else,
`raw-text` and `us-ascii` and the whole UTF-16 family included, has a vector.
`%define-coding-system` builds the vector case; `%define-fixed-eol-coding-system`
is the other, and `no-conversion` uses it. This also fixed the `name-tar` case
for free.

## `tools/coding-diff.py`, and a comparison that was not one

The corpus tool gained an honest third answer from Emacs. Emacs **refuses to
save** a buffer whose characters its coding system cannot encode - it prompts
"Select coding system", which in `--batch` reads stdin, gets EOF and errors -
so the file on disk is still the *input*, and comparing it to schemacs' answer
reads as "Emacs wrote N bytes" when Emacs wrote nothing. `ask_emacs` now reports
`SAVED=` and the tool says so. Two cases were affected:

- `shift-jis`: Emacs reads the bytes as `utf-8-unix` and then cannot save them.
  The *coding* difference is real and is the unported read-path detector, see
  below.
- `name-utf-8`: Emacs names the file `utf-8` from the alist and then cannot
  save Latin-1 bytes. Both cases had passed before by writing nothing.

Now: **19 identical, 2 known-different, 0 new**, exit 0.

## Departures, and whether to fix them

1. **The read-path detector `detect_coding` (`coding.c:6501`) is not ported.**
   Emacs has the detection logic *twice* - `detect_coding_system` (`:8686`),
   which `detect-coding-region` calls and which this tree ports, and
   `detect_coding`, which `decode_coding` calls and so `find-file` uses. They
   are near-copies that disagree: on the `shift-jis` bytes one says
   `japanese-shift-jis-unix` and the other `utf-8-unix`. **This is the last
   real gap in the file path**, and it is what a `shift-jis` file hits.
2. **`iso-2022-jp`** - the 259-line state machine, unchanged and already named.
3. **`*require-final-newline*` is a global `#t` here; Emacs's is a global `nil`
   with `mode-require-final-newline` (t) copied in by the major mode.** So
   Emacs adds a final newline to a `.txt` (text-mode) and *not* to a `.bin`
   (fundamental-mode), and this tree adds one to both. Measured both ways.
   **Worth fixing** when the major modes and `mode-require-final-newline`
   exist; it is not a coding-layer bug and nothing in the coding work depends
   on it. The `shift-jis` case's extra byte is this rule and *matches* Emacs
   for a `.txt` name - Emacs's own side of that case simply never saved.
4. **`coding-system-eol-type` on a name that is not a coding system raises**
   here where Emacs answers nil. Small, and the one caller that could hit it
   is a test.

## Tests

- `coding-tests.scm` 50 (was 46): the mark bytes for all three with-signature
  systems and `#f` for the seven that carry none, and `no-conversion`'s fixed
  eol with no variants beside `raw-text`'s three.
- `ncurses-editor-tests.scm` 240 (was 239): the BOM round trip through
  `find-file-noselect` and `save-buffer` for all three marks, asserting the
  coding system's *name* and the bytes on disk - Emacs 31.1's own answers. It
  fails without the wiring, without the name and without the read strip, each
  on its own.
- `tools/pty-check.py` 61/61, all 31 suites pass, no new compiler warnings.

The `srfi 64` trap caught me twice more here - `coding-system-name` answers a
*symbol* and I wrote the expectations as strings, and `number->string` hex
against `'(ef bb bf)` symbols - both printing as two identical-looking lists.

# iso-2022 is not a 259-line job — corrected sizing (2026-10-06)

Reconnaissance only; no code. This is here so the next session does not repeat
the estimate. The plan (`zany-stargazing-hare.md`, item 7) says:

> `detect_coding_iso_2022` — 259 lines. A genuine state machine, the one big
> detector. iconv has the codecs (`ISO-2022-JP` works), so the detector is the
> whole cost.

**Both sentences are wrong**, and in opposite directions.

## The detector is the small part

`detect_coding_iso_2022` (`coding.c:2923`, ~260 lines) decides each ISO
category with `SAFE_CHARSET_P`, whose `safe_charsets` string comes from
`setup_iso_safe_charsets` (`coding.c:2855`) over the coding system's
`:charset-list`. Measured on Emacs 31.1:

```
iso-2022-7bit        type=iso-2022   charsets=iso-2022
iso-2022-8bit-ss2    type=iso-2022   charsets=iso-2022
iso-2022-7bit-lock   type=iso-2022   charsets=iso-2022
iso-2022-jp          type=iso-2022   charsets=4
```

Three of the four categories answer the *symbol* `iso-2022` — the whole
charset registry, resolved at run time. The designation sequence is turned
into a charset id by `iso_charset_table`, which `define_charset_internal`
(`charset.c:1157`) populates from the charset definitions and their
`charsets/` map files. None of that exists here; it is **item 8** of the same
plan, `charset.c`, 2464 lines.

## iconv does *not* have the codec

This is the part that makes it not-bounded. The corpus case in
`tools/coding-diff.py` is named `iso-2022-7bit` by Emacs — and:

```
$ iconv -l | grep ^ISO-2022
ISO-2022-CN-EXT// ISO-2022-CN// ISO-2022-JP-2// ISO-2022-JP-3//
ISO-2022-JP// ISO-2022-KR//
```

There is no `iso-2022-7bit` in iconv. Emacs's is its own coding system —
`CODING_ISO_FLAG_FULL_SUPPORT` over every registered charset, which is why
its `:charset-list` is the whole registry — and iconv's `ISO-2022-JP` is a
much narrower coding system that merely *agrees on these bytes* (measured:
it does decode them, `あいうえお`). So the port needs
`decode_coding_iso_2022` (`coding.c:3449`, ~900 lines) and
`encode_coding_iso_2022` (`:4364`, ~200) written by hand.

**This is the first place in the whole coding layer where iconv is not the
codec.** Every other family — UTF-8, UTF-16, Latin-1, Shift-JIS, Big5 — leaned
on it, which is what made them cheap; this one cannot.

## The corrected estimate

Item 7 is **~1400 lines of `coding.c` plus the charset registry (item 8)**.
It is not a detector with a codec underneath; it is the registry, a decoder,
an encoder and a detector, in that order, and item 8 comes first. The
honest order is item 8, then item 7 on top of it.

A JISX0208-only table would make the corpus case pass and would be a lie of
the kind this file already has a section about ("a decision I made and then
dressed as fidelity"). Don't.

# The charset registry, metadata first (2026-10-06)

Item 8 of the plan, taken as far as it can be independently verified.
**`schemacs/editor/charset.sld` is new and nothing consumes it yet** - which
is the point: `iso-2022` (item 7) is blocked on it, and this is the half of
it that can be checked against Emacs before anything is built on top.

## What is here, and what is deliberately not

A charset in Emacs is **two things**: its metadata - an id, a dimension, an
ISO final char, a code space, a code offset - and the code-to-character map
that its `:map` names (`charsets/JISX0208.map` and its like). This is the
first. `define-charset` records `:map` and does not load it, so the maps
have their pointer when they come and nothing here pretends to convert a
character.

That split is what makes the job checkable: the entire ISO-2022
designation machinery reads only the metadata.

| | |
|---|---|
| `charset.sld` | the registry: `define-charset`, the charset record, `iso-charset-table`, `*iso-2022-charset-list*` |
| `charset-tests.scm` | 8 tests, every expectation Emacs 31.1's own |
| not here | the `charsets/*.map` maps, `define-charset-alias`, `declare-equiv-charset`, the docstring/short-name/long-name strings |

The data at the bottom of the file is **Emacs 31.1's whole charset set, 179
of them**, emitted by a script that read a running Emacs's registry in id
order - the same method `xterm.sld`'s decode map was transcribed by.

## The three things that had to be measured, not reasoned

1. **`:iso-chars-96` is not a property.** My first probe asked Emacs for it
   and got `nil` for every charset, which reads as "no charset is a
   96-character set" and is false. It is *derived*:
   `charset.iso_chars_96 = charset.code_space[2] == 96` (`charset.c:904`) -
   the count of the **first** dimension. 23 of the 54 are 96-char sets.

2. **`define-charset` normalises before the C sees anything**, in Lisp, in
   two ways that both change the answer. `:code-space` is padded to eight
   elements (`mule.el:270`) because the C's walk reads four pairs whatever
   the caller gave; and `:dimension` is settled from the **original**
   length (`mule.el:251`), so `#(0 127)` is dimension **1** and not the 4
   that padding to eight would suggest. Both are ported, in `define-charset`.

3. **The ids are Emacs's, sparse and shared.** They are handed out across
   *all* 179 charsets, so `iso_charset_table`'s cells hold ids like 5 and 148
   and not 0..53; and an alias shares its target's id - `ucs` *is* `unicode`,
   id 2, and `(get-charset-property s :name)` is how you tell which symbol
   is the canonical one (`:base` is `nil` on every charset the C defines
   itself, so it cannot be used as the test).

## How it is verified, and why that is not circular

`iso-charset` (`charset.c`) is a *reader* of `iso_charset_table` - it takes
a dimension, a character count and a final byte and answers the charset. So
Emacs's own table can be dumped without going through the code being
tested, and that is what the golden list in `charset-tests.scm` is.

It is checked in **both directions**: every one of Emacs's 53 cells answers
the right charset, and a sweep of all 2 x 2 x 79 in-range cells finds no
cell populated that Emacs does not populate. A port that wrote cells too
generously cannot pass the second half.

**53 cells and not 54 charsets**, and the difference is a finding in
itself: `thai-iso8859-11` (id 28) and `thai-tis620` (id 37) are both
designated `ESC ( T`, so the later definition overwrites the earlier one
and the cell holds `thai-tis620`. The port reproduces it because it writes
the cell in definition order too, and there is a test that says so by name.

## What this unblocks, and what is still missing for `iso-2022`

Unblocked: `iso_charset_table` (done, verified), `iso-2022-charset-list`
(done, verified), and `setup_iso_safe_charsets` - which is now a small
function over `iso-2022-charset-list` and each category's `:iso-request`
and `:iso-usage`, and is **not written yet**.

Still missing after that: the four ISO categories as coding systems, the
detector (the 260 lines), and - the large part - `decode_coding_iso_2022`
and `encode_coding_iso_2022`, which have no iconv codec to stand on.

# The line ends were missing from the coding-string API (2026-10-06)

Item 6's other half, plus something bigger that fell out of looking at it.

## The bug

`decode-coding-string` and `encode-coding-string` did **no end-of-line
conversion at all**. Measured on Emacs 31.1 for the same input (`"a\r\nb"`
decoded, `"a\nb"` encoded):

| coding system | Emacs decode | was | now |
|---|---|---|---|
| `utf-8-dos` | `(97 10 98)` | `(97 13 10 98)` | same as Emacs |
| `utf-8-unix` | `(97 13 10 98)` | `(97 13 10 98)` | same |
| `utf-8-mac` | `(97 10 10 98)` | `(97 13 10 98)` | same |
| `raw-text` | `(97 10 98)` | `(97 13 10 98)` | same |
| `no-conversion` | `(97 13 10 98)` | `(97 13 10 98)` | same |

and `utf-8-dos` encoding `"a\nb"` is `(97 13 10 98)` there and was
`(97 10 98)` here.

**It was invisible because the file path does the eol itself.** `files.sld`'s
`decode-file-bytes` walks the codec and then calls `decode-eol`, and
`write-file-code-points` calls `encode-eol` before the codec - so every file
this editor read and wrote came out right while the public API was wrong. Two
copies of a rule, one of them missing, and the tests all went through the
copy that had it.

The C puts it where the name says: `decode_coding` runs the codec over the
bytes and *then* `decode_eol` over what it produced; `encode_coding` runs
`encode_eol` first.

## The undecided case, which is not the same rule

A coding system that has **not named** an end of line takes one from the text
- the C's `detect_eol` inside the decoder, where `coding->eol_type` is a
vector. Measured: `(decode-coding-string "a\r\nb" 'utf-8)` is `(97 10 98)`,
and so are the CR-only and LF-only forms; every line ending comes back as LF.
So `utf-8`, `raw-text`, `undecided` and the rest detect, while a name that
carries an eol (`utf-8-dos`) does not.

On the **encode** side there is nothing to detect, and Emacs inserts nothing:
`(encode-coding-string "a\nb" 'utf-8)` is `(97 10 98)` - the undecided case
is unix. That half already agreed, because `encode-eol` leaves an unnamed eol
alone.

## The NUL rule is the file path's, not this one

`coding-system-for-file` turns a NUL into `unix`, so a binary file's line
ends are left alone - that is `detect_coding_system`'s rule. **This API does
not apply it**, and that is measured rather than assumed: Emacs answers
`(97 0 10 98)` for `"a\0\r\nb"` read as `utf-8` *or* as `raw-text`, the CRLF
gone. I wrote the NUL guard in here first, on the reasoning that the rule
would be shared, and the measurement took it out again.

## Not yet reachable

Nothing calls either function outside `coding.sld` - checked. So this is an
API conformance fix with no user-visible effect *yet*; item 5,
`decode-coding-region` and `encode-coding-region`, is what will use it.

## Tests

`coding-tests.scm` 54 (was 50): the decode table above, the three undecided
forms, the NUL case, and the encode direction.

All 32 suites pass, `tools/pty-check.py` still passes, `coding-diff.py` is
19 identical / 2 known / 0 new.

# `check-coding-system`, and two more plan lines that are wrong (2026-10-06)

## Item 3 is done

`coding-system-p` already answered `#t` for nil (the docstring's "or nil"
was restored earlier); what was missing was **`check-coding-system`**
(`coding.c:8605`), which is now in `coding.sld`. Measured on Emacs 31.1:

| argument | Emacs | now |
|---|---|---|
| `'utf-8` | `utf-8` | same |
| nil | nil | `#f` |
| `'nonsense` | signals "Invalid coding system: nonsense" | same message |
| `"utf-8"` | `wrong-type-argument` | signals |

The last row is the distinction worth having: a **string** is an error here
where `coding-system-p` merely answers nil, because Emacs checks `symbolp`
before the lookup.

Two departures, named in the source rather than hidden: Emacs's
`coding-system-error` is a condition *type* a caller can catch by name and
this raises through `error`, the one condition this tree signals; and the
offending object is not shown in the type-error message, because printing
an arbitrary object the Emacs way needs `prin1`, which lives above this
library.

## Item 5 is not small either: there are no unibyte buffers

The plan says `decode-coding-region` and `encode-coding-region` are
"a copy rather than a conversion here, since the buffer is already code
points". That is the wrong reason but the right conclusion by accident -
and the real blocker is different. Both are thin wrappers over
`code_convert_region`, which is ~70 lines at the DEFUN level, so the size
was never the problem. The problem is what they *mean*:

> If, for instance, you have a region that contains data that represents
> the two bytes #xc2 #xa9, after calling this function with the utf-8
> coding system, the region will contain the single character ©

This tree has **no unibyte buffers** - `enable-multibyte-characters` is
always true here, and `mule.sld` says why - so there is no way to say "this
region holds bytes" and the decode direction has no input to work on. The
contract is not expressible, not merely unimplemented. Porting it needs the
unibyte/multibyte distinction first, which is a different job.

## Item 4 needs a chain, and the docstrings are the point

`list-coding-systems` (`mule-diag.el:748`) is a dozen lines, but
`print-coding-system-briefly` wants `coding-system-list`,
`sort-coding-systems`, `coding-system-aliases` and
`coding-system-doc-string`, and **our coding systems carry no docstrings at
all** - which is what the command exists to show ("This shows the mnemonic
letter, name, and description of each coding system"). Its alias branch also
reads `coding-system-eol-type` as an *integer index into the base's vector*
of variants, which is not the shape this tree settled on (`mule-cmds.sld`
records that departure).

So item 4 is: docstrings as data (script-emittable from Emacs, the charset
registry's method), four small accessors, a `*Help*` buffer - one exists in
`replace.sld` to copy - and then the command. Bounded, but a pass of its
own, not the "small buffer" the plan implies.

**All 32 suites pass (coding-tests 56), no new warnings.**

# Coding-system docstrings, and what is left of item 4 (2026-10-06)

Item 4's first half: **the docstrings existed nowhere in this tree**. Emacs
carries one per coding system and `list-coding-systems` exists to show it
("This shows the mnemonic letter, name, and description of each coding
system"), so the command could not have been written without them.

Landed:

- `*coding-system-docstrings*` in `coding.sld` - **Emacs 31.1's own text
  for all fifteen** of this tree's coding systems, emitted by a script from
  a running Emacs, the method the charset registry used. Kept as a table
  rather than inline because two (`no-conversion`, `raw-text`) are
  multi-line paragraphs.
- A `docstring` field on the record, inherited by the `-unix`/`-dos`/`-mac`
  variants.
- `coding-system-doc-string` (`mule.el:1045`), `coding-system-aliases`, and
  `coding-system-list` with its `base-only` form - which is the names that
  are their own `base`, so every eol variant drops out.

Two departures, both named in the source: **this tree has no coding-system
aliases** (`define-coding-system-alias` is not ported, so Emacs's `binary`,
`mule-utf-8`, `latin-1` do not exist here), so `coding-system-aliases`
answers the name alone - `(car ...)` is the name in both, which is what its
one caller reads; and `iso-8859-1` is a coding system *here* where in Emacs
it is an alias of `iso-latin-1`.

## What item 4 still needs

`list-coding-systems` itself, and `sort-coding-systems` underneath it.
**`sort-coding-systems` (`mule-cmds.el:429`) is blocked on the language
environment** - its priority is a `logior` over "is the most preferred",
"has a MIME charset", "is in `current-language-environment`'s `coding-system`
key", "is in the category list", and "is ISO-2022 and which of 0..3".
`language-info-alist` and the language environments are not ported at all.
So item 4 is: this (done), then the language-environment machinery or an
honest subset of the priority rule, then the command and its `*Help*`
buffer.

**All 32 suites pass (coding-tests 62), no new warnings.**

# Frames: the list, the selection, and C-x 5 (2026-10-06)

The editor had **exactly one frame**, made at startup, and no way to have
another. That is now the Emacs model.

## First: does a tty have frames? Yes, and I checked

Emacs on a terminal really does create them - `emacs -nw` in a pty with
`(make-frame)` answers `frames=2`. What differs is only what it *looks* like:

- **GUI**: a frame is an OS window; a second frame is a second window.
- **tty**: a frame is a *screen* on that terminal. There are no windows, so a
  second frame is **invisible** - it exists, it is in `frame-list`, it is
  selectable, and the terminal still shows one frame at a time until `C-x 5 o`
  switches. `make_terminal_frame`'s own docstring (`frame.c:1741'): "You can
  create multiple frames on a single text terminal, but only one of them (the
  selected terminal frame) is actually displayed."

That is why nobody has seen a tty frame. It is not that they do not exist.

**Scope agreed with Chris: GUI frames first.** A GTK frame is a window you
can see; the tty backend is a stub that Emacs's own design anticipates
(`frame-creation-function` is a `cl-defgeneric` with one method per
window-system, `frame.el:30-46`).

## The bug the design review caught in my own plan

I first planned to replace `(current-display)` with the frame's output at the
~40 draw call sites in `xdisp.sld`. That was wrong twice over:

- It is the most fragile code in the tree and ncurses shares it.
- **It would not have worked.** `render-window!` picks the mode-line face
  through `selected-window`, which is `(frame-selected-window
  (*current-frame*))` (`frame.sld:1185', used at `xdisp.sld:2322'), and the
  cursor type comes from `*frame-focus*`. Frame B would have been drawn with
  **A's** selected mode line and A's cursor.

The fix is to bind **both** parameters at the `render!' boundary and leave
the body alone. With one frame it is an identity rebind - which is why the
suites passed unchanged - and it makes `frame-output' live instead of dead.

## Two facts read out of the source, because the design rests on them

- `f->terminal` is assigned **only at creation** (`frame.c:1446' in
  `make_frame', `:1566' in `make_terminal_frame') and nulled at death
  (`:2940'). Never reassigned. So a frame's display is fixed for its life,
  which is what makes reading `frame-output' safe rather than re-deriving it.
- Redisplay reaches the terminal **through the frame**:
  `FRAME_TERMINAL (f)->...' throughout `dispnew.c'/`xdisp.c'. There is no
  global terminal.

## A finding that shapes the next phase

**Emacs's redisplay is a loop over every frame** -
`FOR_EACH_FRAME (tail, frame)` at `xdisp.c:14350' and `:14291', with
`consider_all_windows_p' deciding whether to mend all windows on all frames
or only the selected frame's. Our `render!' renders **one** frame, the one
the command loop hands it. So with two windows, editing in A leaves B stale:
Emacs redraws both because redisplay is a frame loop, not a call.

## Bugs in my own work, and how each was caught

1. **`make-frame` passed parameter *objects* to `run-hooks`.** I wrote
   `(run-hooks *before-make-frame-hook*)' where a parameter is a
   *procedure* - so `run-hooks` called it with no arguments, discarded the
   value, and ran nothing. It is `(*before-make-frame-hook*)'. Caught by the
   test asserting the hook order.
2. **A missing import** (`*before-make-frame-hook*` in the test file) - the
   class this file has a section about, for the umpteenth time.
3. **A paren splice that broke the file, and I did not re-run
   `syntax-check` after it.** The symptom was the worst kind: the suite ran
   four test groups, printed four PASSes, then **died with exit 1 and no
   error at all**, which read as a hang or a record-printer crash and sent me
   guessing. `guile -s tools/syntax-check.scm` named it in one line. Run it
   after *every* scripted edit, including a splice you are sure about.
4. **Tests asserting literal frame names.** Emacs hands out `F1', `F2', ...
   off a counter that lives as long as the editor, so by the time a test runs
   the numbers are in the hundreds and a literal `F2' means nothing. The
   tests assert by frame *identity* now.
5. **A test passed `#t' as FRAME** where Emacs's second argument is FORCE -
   and that exposed a real gap: my `delete-frame` returned `nil` for
   something that is not a frame at all. Emacs type-errors there
   (`CHECK_LIVE_FRAME`) and answers nil only for a frame that is merely
   *dead* (`frame.c:2611'). Fixed.

## What is named as not carried

Frame **parameters** - which is most of what Emacs's `make-frame` does, since
it merges `window-system-default-frame-alist`, `default-frame-alist` and
`frame-inherited-parameters` before creating anything. A frame here has no
parameters to merge. Also not carried: aliases, child frames, tooltip frames,
surrogate minibuffer frames, iconification, the MRU list
(`delete-frame-choose-selected`), the `delete-frame-functions` and
`after-delete-frame-functions` hooks, and the exit-70 path for forcibly
deleting the last frame. `display-make-frame` is not a display generic yet,
so with no `frame-creation-function` installed `make-frame` reports "This
display cannot make more frames" instead of making one.

**Verified:** 32 suites, ncurses-editor-tests 250 (was 240), no new
warnings. `tools/pty-check.py` is the ncurses regression check for the
`render!` change and is run on its own.

# Two frames on one buffer: the point is per window (2026-10-07)

Chris: *"C-x 5 2 opens another frame but they both scroll together."*

Frames landed over `474a99f`, `1762d75` and `279d4b3` plus the uncommitted
work that lets a second GTK window draw and take input. This is the pass that
made a frame its own view of the buffer rather than a second pane on one.

## The root cause, and the one line of C that names it

`window_point` (`window.c:1778`) is

```c
return (w == XWINDOW (selected_window)
        ? BUF_PT (XBUFFER (w->contents))
        : XMARKER (w->pointm)->charpos);
```

`selected_window` is a **global** - the selected window of the selected frame
- and redisplay's frame loop (`FOR_EACH_FRAME`, `xdisp.c:14350`) never changes
it. Two things here departed from that, and both are the same mistake seen
from different sides: *the window being drawn* was being treated as *the
selected window*.

### 1. `render!` bound `*current-frame*` to the frame it was drawing

`schemacs/editor/xdisp.sld`'s `render!` wrapped its whole body in
`(parameterize ((current-display …) (*current-frame* frame)) …)`. But
`*current-frame*` is also what `selected-window`, `window-point` and the
mode-line face read. So while frame B was drawn, B's window *was* the selected
window, and `window-point` answered the buffer's point - which is where frame
A was scrolled to.

The binding is gone; the display binding stays (that is `FRAME_TERMINAL (f)').
The three draw-path readers that genuinely needed the *drawn* frame now ask
the window for it - `window-frame`, below - because Emacs does:

- `window-full-width?` → `WINDOW_FULL_WIDTH_P`, `WINDOW_XFRAME (W)`
  (`window.h:701`);
- `window-right-border?` (and so `window-body-width`, and so the wrapping) →
  `WINDOW_RIGHTMOST_P`, `WINDOW_XFRAME (W)` (`window.h:687`);
- `get-window-cursor-type` → `XFRAME (w->frame)`'s selected window plus the
  highlight frame (`xdisp.c:34847`).

The mode-line face and `window-point` are the other way round: Emacs compares
both against the **global** selected window (`EQ (window, selected_window)`,
`xdisp.c:29108`), so *removing* the binding is what made them right.

### 2. `select-frame` never swapped the point

`select-window` (`frame.sld`) already ported `select_window_1`
(`window.c:591`) correctly. `select-frame` did not, and Emacs's
`do_switch_frame` ends with

```c
Fselect_window (f->selected_window, norecord);   /* frame.c */
```

which is what runs that swap. So switching frames saved nothing and restored
nothing and every frame was pinned to one point. `select-frame` now does the
two steps - save the old frame's selected window's point into its
`%window-point`, then give the buffer the new one's - guarded on the frame
actually changing, which is `select_window`'s early return (`window.c:545`).

**`let*` and not `let`** for that guard: a `let` binding's init is evaluated in
the enclosing scope, so `(eq? old frame)` in a `let` is an unbound `old`. The
repro caught it in one run.

### 3. A new frame's window started at point 1

`make-frame-window` built the window with `(copy-marker buffer 1)` for both
point and start. `set_window_buffer` sets the point marker from the buffer
(`window.c:4375`), so `C-x 5 2` should open at the place you are. Measured on
Emacs 31.1: point at 21, the new frame's `window-point` is 21.

## Two more, found underneath

### `scroll-to-cursor!` and `hscroll-window!` read the *buffer's* cursor

Fixing the binding alone did nothing, and this is why: `scroll-to-cursor!`
scrolled every window to `(text-editor-cursor-column ed)` - the buffer's own
point - rather than to the window's. The C asks `window_point (w)`
(`xdisp.c:16809`):

```c
if (w == XWINDOW (selected_window)) pt = PT;
else pt = clip_to_bounds (BEGV, marker_position (w->pointm), ZV);
```

Both functions now work from `(window-point window)`. `cursor-screen-position`,
`cursor-glyph` and `cursor-cells` had the same shape and are fixed with them -
`cursor-glyph`/`cursor-cells` took the buffer and now take a *position*, so the
echo area (which is not a window) passes its buffer's cursor and the window
path passes the window's point.

### `cursor-screen-position` answered *unspecified*, not `#f`

Its docstring has always said "or `#f` when it is scrolled out of view", and
it was a `(when …)`: a `when` whose test fails answers the *unspecified* value,
**which is true in Scheme**. So the caller's `(when at …)` drew a cursor at
`(car #<unspecified>)` and died -

```
Wrong type argument in position 1 (expecting pair): #<unspecified>
```

- which only became reachable once a frame that is not selected had its own
cursor placed. It is an `if` with a `#f` now. Worth remembering: a `when` used
as an expression is not Emacs's `nil`.

## Tests

- `schemacs/apps/ncurses-editor-tests.scm` +5 (`..._frame_points`, 254): two
  frames on one buffer - point per frame across `select-frame` in both
  directions, `window-point` of a *non-selected* frame's window, a new frame
  inheriting the buffer's point, and scrolling being per window. Every number
  is Emacs 31.1's, measured in a pty on the same text.
- `schemacs/editor/pgtk-tests.scm` +1 (48): two frames on **two** displays,
  both rendered, asserting their `window-start`s differ. This is the only test
  that reaches the `render!` binding; the ncurses suite cannot call `render!`.
- Three existing `cursor_position` tests now bind `*current-frame*`, because
  the cursor's position is `window-point`'s and only the selected window's
  point is the buffer's - the binding `render!` is called under.
- Each new test was run with its fix reverted and seen to fail:
  `(#f #t)` for the scroll rule, `(111 111 205 205 205)` for the swap,
  `(#f #t)` for the render binding.

All 32 suites pass, `tools/pty-check.py` passes, no new compiler warnings.

## Departures introduced or named

- **`*frame-focus*` is still one flag**, where Emacs's `highlight_frame` is
  per display. `get-window-cursor-type` now reads it as "the display has
  focus *and* that frame is the selected one", which is the nearest this tree
  can say; with a single frame it is exactly what it read before.
- **No C-x 5 test exists anywhere** though the bindings do (`frame.sld`).

# `w->frame`, the echo area's frame, and the buffer following the frame
# (2026-10-07)

Chris, on the pass above: *"you didn't fix the window-frame thing because it
invalidates .go files? What sort of retarded thing is that? Every time you
make a change I have to recompile every .go. and why you make one echo area,
that's retarded, when I type in the minibuffer it comes up on all frames. and
you don't make the new frame buffer current? I guess that's why all the
commands don't work when you switch frames?"*

All three, and the first is the one worth reading: **the `.go` cache is a
build artefact, not a design constraint.** Refusing a record field because
recompiling is inconvenient is the "improvise around the missing primitive"
that the top of this file forbids - and it bought nothing, because the field
has to exist eventually anyway. The three bullets above that named it, the
echo area and the buffer as departures "deliberately not done" are gone.

## 1. `<window>` carries its frame (Emacs's `w->frame`)

A field again, first in the record, as it is first in `struct window`
(`window.h`). Set where Emacs sets it: `new-frame-on` makes the *frame
object first* and its windows second, which is `make_frame`'s own order
(`frame.c:1229`) - `root_window = make_window ()` then `wset_frame (rw,
frame)` - and `split-window` gives the new window the frame of the window
it split (`frame = WINDOW_FRAME (o)`, `window.c:5412`, `wset_frame (n,
frame)`, `:5583`). That is why `make-frame-window` and the four `make<window>`
sites take a frame now: a window's frame is fixed for its life, so it cannot
be filled in afterwards.

The walking `window-frame` is deleted. It answered the same thing, which is
exactly why it was the wrong shape: it made a window's frame a fact about
`*frame-list*` rather than about the window.

## 2. The echo area is drawn on one frame

`*echo-area-buffer*` being a single buffer is **not** the departure - Emacs's
`echo_area_buffer[0]` is a global too (`xdisp.c:785`). The departure was
*where it is drawn*. `echo_area_window` is
`FRAME_MINIBUF_WINDOW (SELECTED_FRAME ())` (`xdisp.c:13782`) and
`redisplay_window` draws the message only for a window that *is* that one
(`:20526`); every other frame's minibuffer window is blank. `render!` drew
it on every frame it was passed, so the prompt - and every character typed
into the minibuffer - appeared in all of them. The block is now gated on
`(eq? frame (*current-frame*))`, and the cursor with it: a frame that is not
selected draws its own window's cursor as usual.

## 3. The current buffer follows the frame - and the window

`Fselect_window`'s **first line** is `Fset_buffer (w->contents)`
(`window.c:534`), "Make the selected window's buffer current", and it runs
before the C even tests whether the window is already selected.
`do_switch_frame` reaches it for every frame switch because it ends in
`Fselect_window (f->selected_window, norecord)`. Neither `select-window` nor
`select-frame` did it here, so after `C-x 5 o` every command still acted on
the buffer the frame you *left* was showing while the screen showed the
other one.

`select-window` and `select-frame` now both do it. The answer is
`(current-editor)` rather than the window's buffer, because during a
minibuffer read Emacs's selected window *is* the minibuffer window; this
tree has no minibuffer window, and the echo area is what stands for it.

**The layering had to move for this, and that was the real blocker.**
`(schemacs editor buffer)` imports `(schemacs editor frame)`, so `frame.sld`
cannot call `set-buffer` - and that is why the previous pass left the half
undone and named it a departure. The fix is not a hook: `*current-buffer*`
moved *down* to `frame.sld`, beside `*current-frame*` and
`*echo-area-buffer*`, which is where the other dynamically-current things
already live. `buffer.sld` imports it and re-exports it, so every existing
importer is unchanged. **When a port needs a C function to write state that
lives in a library below it, the state is in the wrong library.**

## The test this shook out

`ncurses-editor-tests` went red at the Insert key, and the cause was worth
the hunt: `delete-window` on the selected window *selects another* - correct
- and that selection now pins `*current-buffer*` globally, because that test
parameterizes `*current-frame*` but not `*current-buffer*`. The next test
then inherited the pin and toggled `overwrite-mode` on a buffer nobody was
showing. The file already documents this hazard and binds `*current-buffer*
#f` in thirty places; that test now does too. Nothing was wrong with the
code - but it is worth knowing that **`*current-buffer*` can now be pinned
by window selection, so a test that fabricates a frame with `parameterize`
must bind it.**

## Tests

- `ncurses-editor-tests` +3 (257): selecting a frame makes its window's
  buffer current, selecting a *window* does too, and every window of a split
  is on the frame it was made on. The first two pin the buffer with
  `set-buffer` first, because with the parameter unset the right answer
  arrives by accident through `current-editor` and the test would pass either
  way. Verified failing on the baseline: `(#t #f)` and `(#f #t)`.
- `pgtk-tests` +1 (49): a pixel check - a message set on the *non-selected*
  frame leaves its echo row blank, and the same message on the selected
  frame inks it. Verified failing with the gate removed: `(#f #t)`.
- All 32 suites pass, `tools/pty-check.py` 61/61, no new compiler warnings,
  and the live editor driven through the REPL back door: two frames, two
  buffers, `(current-buffer)` correct after `select-frame` in both
  directions.

## Still named, not fixed

- **`*frame-focus*` is one flag**, where Emacs's `highlight_frame` is per
  display.
- **`select-window` on a window of a *non-selected* frame does not switch
  frames.** Emacs's does: `if (f != sf) { fset_selected_window (f, window);
  Fselect_frame (frame, norecord); ... }` (`window.c:562`). Nothing here
  reaches it yet, and the port would need care - `Fselect_frame` calls back
  into `Fselect_window`.
- **No C-x 5 test exists anywhere** though the bindings do (`frame.sld`).

# The GTK editor burned 27% of a core doing nothing (2026-10-07)

Chris, from using it: *"C-n is rather slow in gtk"*, then *"you opened 2
editors and both of them are burning about 25% CPU doing nothing"*.

Both are the same fact. **It was the development REPL.**

## The chain, and the one link that took all the work

1. `~/.config/schemacs/init.scm` calls `(start-repl!)` **unconditionally**,
   so *every* editor has the back door open.
2. `repl-open?` is therefore always true, so `read-wait-ms`/the command
   loop always **caps the read's wait at 100 ms** - the cap exists so the
   cooperative server gets a turn (`frame.sld` and `repl.sld` both say so).
3. So a GLib deadline source is armed on every read, and an idle editor
   **wakes 10-16 times a second** with nothing whatever to do.
4. Each wake costs **~13 ms of CPU**, measured: four guile-gi crossings
   (`main-loop:quit`, `main-loop:run`, `timeout-add`, `source-remove?`) at
   ~3 ms each.

16 x 13 ms is the ~21%, and with the redisplay on top it is the 27%.

**Measured, same editor, same window, the only difference the config:**

| | idle CPU |
|---|---|
| with `init.scm` (REPL open, deadline armed) | **27%** |
| with an empty `XDG_CONFIG_HOME` (no init, no REPL) | **2.6%** |

## The measurement method, which is half the lesson

- **`ps`'s `%CPU` is a lifetime average**, not a rate. Reading it made me
  report "0%" while Chris watched 25% in front of him. Read `utime` and
  `stime` out of `/proc/PID/stat` twice and divide by the interval.
- **Split user from system time.** The burn was **90% system** - a syscall
  storm, ~1900 voluntary context switches/s - which rules out Scheme and
  GOOPS as the cause before any profiling is done.
- **`statprof` lies about syscalls.** It samples on `ITIMER_PROF`, and
  Guile attributes a sample taken inside a syscall to the *Scheme frame
  that made the call* - so `class-precedence-list` and `program-name`
  looked like 42% of the time, and I concluded "guile-gi dispatch" and
  said so. The real cost was the kernel. Ask user-versus-system first.
- **`gdb`/`strace` are not installed here, and `/proc/PID/syscall` is
  blocked** (yama, because the editor is nobody's child). What worked was
  counters compiled into the source, read back through the REPL with
  `module-ref` - **not** `module-set!`, which silently fails to intercept
  calls from already-compiled code.
- **A window on the desktop is not needed to be wrong about this, but it
  is needed to be right**: the headless command loop idles at 0% and
  reproduces nothing. It took a real `./seg` run to see it.

## What landed

- **`pgtk-read-event` waits in a nested `GMainLoop`**, not in a hand-driven
  pump. `pgtk-wait!` runs one `g_main_loop_run`, and `pgtk-enqueue!` - the
  single place every key, resize, focus and deadline goes through - is
  what quits it. The loop is made once and run again per wait, which a
  `GMainLoop` allows.
  `main-iteration-do?` is gone from the tree.
  Verified: a read with a 100 ms deadline answers in 117 ms; a blocking
  read woken by an enqueue at 50 ms answers in 72 ms with the right code.
- **The widget allocation is remembered, not asked** (`pgtk-allocated-size`,
  recorded by the `size-allocate` signal - Emacs's `FRAME_PIXEL_WIDTH`
  refreshed from the configure event). `widget:get-allocated-width` costs
  **3.2 ms**, and a redraw asked twice, so four property reads were ~13 ms
  of a keystroke's ~21 ms. In-process A/B: redraw **24.4 -> 18.5 ms**.
- **A dead guard was removed** from `pgtk-read-event`: it called
  `pgtk-allocation` on every read and compared it against a slot
  (`drawn-size`) that nothing ever set, so the branch could never fire.

## The harnesses no longer load a developer's config

Chris: *"all your tests and test harnesses should really set
XDG_CONFIG_HOME so that they are not affected by my personal config"* -
right, and it is why the numbers above were confusing for so long.
`tools/pty-check.py` and `tools/run-suites.py` now point
`XDG_CONFIG_HOME` at an empty `mkdtemp`, so a run depends on the tree and
nothing else. Verified: no REPL port file is written by a check any more.
The legacy `$HOME/.schemacs` is still reachable when a developer has one.

## Still to do

- **The REPL should not need a wake-up.** The cap is still there and still
  costs what the table above says. The fix is a thread that reads and
  parses and posts the work to the main thread with `idle-add` - the
  tree's own note explains why the *cooperative* server was chosen
  (a parameter binding is thread-local, so the server thread sees the
  defaults of everything `parameterize` set), and posting to the main
  thread is how that is solved properly rather than avoided.
- **Incremental redraw.** `render!` still clears the whole surface and
  re-renders every row of every window for a keystroke that only moved the
  cursor. Emacs skips windows that did not change (`w->redisplay`) and
  diffs the glyph rows within one that did (`try_window_id`), and redraws
  the mode line only when `mode_line_update_needed` says so. A
  non-scrolling `C-n` should cost a cursor erase-and-draw, not a frame.

## `tools/pty-check.py` was a race, and every 61/61 was it winning

Found while isolating the harnesses from the developer's config: with no
`init.scm` (and so no REPL, and so no 100 ms cap on the read) the battery
gave **58/61, then 57/61, then 52/61** - a *different* scattered set each
time. With the config restored it gave 61/61, under a *lower* load average
than the failing runs. That pair of facts is the whole diagnosis: not
systemic, and not the editor.

The harness settled with fixed sleeps:

    time.sleep(0.6); drain(0.2)

- send the keys, sleep a fixed 0.8 s in all, **kill the editor**, and grep
the transcript collected so far. Nothing ever waited for the expected text
to appear, so every check was a race with the editor's redisplay, and the
100 ms cap was masking it by giving the editor ten extra turns inside that
window. Removing the cap shortened the odds; it did not cause the misses.

`drain` now answers how many bytes it read, and the settle waits for the
editor to be **quiet for 0.4 s** (`QUIET`) with a 20 s backstop
(`SETTLE_MAX`). A redisplay is one burst, so silence is the end of it.

That takes the battery from **52-58/61 to 60-61/61**: it is no longer
load-sensitive in the way it was, but it is not deterministic yet. One run
in the batch gave 60/61 on `find-file-read-only`, which passes four times
out of four when it is run on its own - so what is left is not the settle
but the *keys*: that check sends `C-x C-r`, then `C-a C-k` 0.35 s later to
clear the prompt, and a busier machine can still be slower than that to put
the prompt up. Waiting for what a check expects before sending the next key
is the real fix, and it means threading the expectations through `drive`
and its sixty-odd callers.

**Two things to carry from this.** A 61/61 that goes through a race is not
evidence, and this one had been for months - the counts above are what a
green run and a red run look like when the difference is only how fast the
machine got through the commands. And a harness that inherits the
developer's `init.scm` is not testing the tree: `init.scm` here opens the
REPL back door, which changes *how the editor waits for every key*.

## The REPL is ours now, so it can be woken instead of polled (2026-10-07)

The other half of the idle-CPU work. The chain in the section above ended
at "the REPL should not need a wake-up", and this is that.

### Why it could not simply be kept

`(system repl coop-server)` is a **pull**: its reader thread reads an
expression and posts it to a queue, and the main thread must call
`poll-coop-repl-server`. Worse, that call is not a status check - it is
what *resumes* the REPL, by calling the continuation the session's prompt
saved (`((coop-repl-cont coop-repl) exp)`). So there is no way to use it
without either polling or a thread waiting on its condition variable.

Tapping it is possible - the client port reaches the main thread, and
Guile tracks open clients in `*open-sockets*`, which `module-ref` can
reach - but it means depending on unexported internals in the one tool
whose whole value is that it does not lie.

### What was done

`schemacs/repl.sld` is `(system repl coop-server)` **copied**, plus one
line. The copy is deliberate and the correspondence is meant to be
obvious: the records, the queue, the reader thread, the prompt that
suspends the session so the editor keeps running, and `poll-repl!`
itself are Guile's.

The line is at the end of `coop-repl-server-eval`, which is the **one**
place every queued operation goes through - a new client and an
expression alike:

    (with-mutex ... (enq! queue (cons opcode args)))
    (wake!)

`*repl-wake*` is that parameter: how *this* front end is told there is
work, or `#f` when it cannot be told. Gtk sets it in `with-gtk-display`
to an `idle-add` - which the main loop runs out of the very
`g_main_loop_run` the read is blocked in. `keyboard.sld` now reads

    (and (repl-open?) (not (*repl-wake*)) 100)

so the cap is asked for only by a front end that cannot be woken. The
terminal still is one, and still gets it.

**Measured, same editor, `init.scm` loaded so the REPL is open:**

| | idle CPU |
|---|---|
| polling (the 100 ms cap) | **27%** |
| woken (`idle-add`) | **0.0% - 0.3%** |

and `tools/repl.py` still answers while the editor sits idle, which is
the whole point of the back door.

### What the port cost, and the trap in it

`(system repl repl)`'s `start-repl*` and `prompting-meta-read`, and
`(system repl server)`'s `run-server*`, are reached with `@@` - which is
what Guile's own coop server does, so it is a technique rather than a
trick. **A name that is missing from the import list is not a load
error.** It sits inside a procedure body, so it is an unbound variable
the first time that body runs - and for
`with-continuation-barrier` that is the first connection, not the load.
Two were found that way (`with-continuation-barrier`,
`current-warning-port`) and one more was a plain mistake: a misplaced
paren made `false-if-exception` a *second argument* to
`coop-repl-prompt`, which the reader accepted happily and which failed
with "Wrong number of arguments to #<procedure coop-repl-prompt (a)>" at
the first connection. `tools/syntax-check.scm` cannot see either class.
**Exercise the code; loading it proves nothing.**

### Still to do here

- **DONE - the terminal is onto `select` + a self-pipe**, so both front
  ends have one shape and no cap is needed anywhere. See "The terminal's
  wake: landed" at the end of this file; the notice below asking for it is
  kept only for the shape of the problem. SIGWINCH needs no plumbing:
  `select(2)` is in the documented never-restarted list (`man 7 signal`),
  so the signal interrupts the wait, and `getch` with `nodelay` then
  picks up ncurses's `KEY_RESIZE`. Confirmed both in the manual and by
  measurement - Guile's `select` returns with an empty ready-set rather
  than resting for its full timeout.
- **The pty battery still flakes about one check in two runs**, and the
  candidates are the ones whose output is not a direct answer to a key:
  `quit-completions` (which asserts the editor *exited* after `C-x C-c`)
  and `default-directory`. The per-key settle waits for the editor to go
  quiet, and quiet is not the same as *done* when what a check waits for
  is produced later than the last key. Waiting for the expected text -
  threading the expectations through `drive` and its sixty-odd callers -
  is the fix; it has not been done. A green battery before that change
  was a race that happened to be won.

## The startup wait was a race too (2026-10-08)

The same class, one level up, and it took a loaded machine to show it. On
a desktop at load average 4 the battery gave **22/62** - forty checks,
scattered, all failing as if the *bindings* were gone: `C-u 5 a` saved
`5ahello`, `x` in Dired "was unbound and self-inserted", `C-q C-g` inserted
nothing, `M-~` said nothing, `redisplay` reported "the buffer was never
drawn". Re-running a few of them by hand they passed; re-running them on
the same tree with the machine quiet they passed; and the tree had not
changed between the two battery runs.

**The cause is the terminal, not the editor.** A key sent before ncurses
has put the tty into raw mode is eaten by the line discipline - `C-u` is
`kill-line` there, `C-c` is SIGINT, `C-q` is `start` - so `C-u` in
`C-u 5 a` vanished without a trace and the check failed for a reason that
had nothing to do with what it tests. `drive` waited a fixed `settle`
seconds (1.5 by default, and the checks that had been flaky pass 2.0-2.5,
which is the tune-by-hand version of the same guess), and a loaded machine
needs longer to load the libraries than that.

`drive` now waits for the editor to *draw and go quiet* (the rule the
per-key waits already use), with `settle` kept as the floor every
check has always had and `SETTLE_MAX` as the backstop. Verified under
deliberate load (six busy loops): 6/6 on checks that had failed. The full
battery then gave **61/62** - `isearch-quit`, "after C-s C-s C-x C-c the
editor is still running (the search ate the C-x)" - which is the
*between-key* race the section above names, not this one: it passes 3/3 on
its own and the whole isearch group with the other three known-flaky
checks passes 8/8 together. **The startup race is fixed; the between-key
one is still there, and its fix is still the one named above - waiting for
what a check expects before sending the next key.**

The lesson is the one this file keeps relearning: a fixed sleep standing in
for "the editor is ready" is a race, and it loses exactly when the machine
is busy - which is when you least want to be told the wrong thing about
your own code. And note what the failure *looked like*: forty checks about
key bindings, on a tree whose key bindings were fine.

A separate note from the same run, because it looked like a regression and
was not: `.go` cache state does *not* change how long this takes.
Measured on this tree, start to first screen drawn: 0.28 s with a warm
cache, 1.25 s with `~/.cache/guile/ccache` deleted (`--no-auto-compile`
reads the sources and compiles nothing). Both are well inside the old
1.5 s, which is why the cache was never the explanation.

**But the cache *does* reach the screen.** A source file newer than its
`.go` makes Guile print

    ;;; note: source file ./schemacs/editor/startup.sld
    ;;;       newer than compiled /home/chris/.cache/.../startup.sld.go

and the editor's stderr *is the terminal* here, so that note lands in the
middle of what a check reads - twice during the splash work a check failed
on a screen full of notes rather than on the thing it was testing. Compile
the tree (`for f in schemacs/**/*.sld; do guile --r7rs -L . -c "(compile-file \"$f\")"; done`)
before a battery run, and after editing anything, so that the cache is
newer than every source. A scripted edit-and-compile can still lose the
race on mtime *granularity* - the write and the compile inside one second
- which shows up the same way.

# The echo area's timers, and the REPL wake that never fired (2026-10-07)

Two things, and the second is a correction to the section above it: **the
"woken, 0.0%" row in the idle-CPU table was measuring a REPL that had
stopped working.** The burn really was the cap, and the cap really is
gone - but for a while the editor could not hear the back door at all,
and 0% CPU is what that looks like too.

## 1. The echo area's two clock-driven habits are timers now

Chris chose the option, and it is Emacs's: *"the first option, arm a one
shot timer sounds more elegant, and if that's what emacs does, that's
another thing in its favor."* It is what Emacs does - `minibuffer-message`
ends with

```elisp
(setq minibuffer--message-timer
      (run-at-time (or minibuffer-message-timeout 1000000) nil
                   #'minibuffer--delete-message-overlay))
(add-hook 'pre-command-hook #'minibuffer--delete-message-overlay)
```

and `clear-minibuffer-message` (`minibuffer.el:1050`) cancels that timer.
So the **timer is owned by whoever set the message**, and cancelled when
the message is cleared - not a timestamp the command loop polls.

- **`<frame>`'s `message-expiry` field is gone; `message-timer` holds the
  timer**, which is Emacs's `minibuffer-message-timer`. `set-message!`
  arms it; `set!frame-message` cancels it (`frame-cancel-message-timer!`).
  `frame-message-expired?` is deleted - there is nothing left to compare.
- **The prefix description is a timer too** (`simple.sld`'s
  `*prefix-echo-timer*`, armed by `request-prefix-echo!` and cancelled by
  `clear-prefix!`). This one is a *translation* rather than a copy, and
  the difference is named in the source: Emacs expresses "the keyboard has
  been quiet for `echo-keystrokes`" as `sit_for (Vecho_keystrokes, 1, 1)`
  in `read_char` (`keyboard.c:2887`) - a *wait* - and a front end that
  owns its loop has no wait to time. Same condition, same one-shot timer
  as the message's.
- **`keyboard.sld`'s command loop loses the whole housekeeping branch.**
  `message-read-timeout` is deleted. The read is now `(read-timeout-or -1
  (timer-next-delay) cap)` - `-1`, blocking, with `timer-next-delay`
  shortening it to the next timer, which is where a message timeout and a
  pending prefix echo now arrive.

Verified live on GTK through the REPL, which is the only way to see it:
`(set-message! f "hello there" 1)` leaves `("hello there" #t)` and two
seconds later, with **no keypress**, it is `("" #f)`. And dispatching a
real `C-u` gives `((4) "")` at once and `((4) "C-u")` a second later with
nothing typed; dispatching `C-u` and then a key gives `(#f "")` and
stays empty - both halves of "whichever comes first".

## 2. `*repl-wake*` was a parameter, so the wake never fired

**The bug.** `wake!` is called from the server's *reader thread*. A
`make-parameter` value is a fluid, and **a fluid's value is captured per
thread at the moment the thread is made**. `main-gtk.scm` runs
`start-repl!` *before* `main-gtk`, so the accept thread - and every reader
thread it spawns - was made before `with-gtk-display` set `*repl-wake*`.
Measured, both ways:

```
made-inside: set
made-before: root
```

So the main thread saw the wake (and so dropped its cap) while every
server thread saw `#f` (and so never woke anything). Result: an idle
editor that answered a REPL only after a keystroke, at **0% CPU**. That
0% is exactly what the previous section recorded as the fix working.

**How it was caught.** `tools/repl.py -p <port> '(+ 1 2)'` against an
idle editor timed out - including against an editor started *before* this
session's edits, which is what makes it pre-existing rather than
introduced here. And `ps -o pcpu` is not evidence either way; it said 25%
for an editor that was doing nothing, because it is a lifetime average
over a cold-cache compile (AGENTS.md already warns about this, twice).

**The fix.** `*repl-wake*` is gone; `(schemacs repl)` exports `repl-wake`
and `set-repl-wake!` over a plain variable. The value is a fact about the
process - which front end this is - not state that varies with the dynamic
extent, so a fluid was the wrong tool for it. `pgtk.sld` sets it with
`set-repl-wake!`; `keyboard.sld` reads it with `(repl-wake)`.

**And it is still not enough to be idle-correct on a terminal**, where the
wake has to be a byte written to a descriptor the wait selects on - which
is the next thing, below.

## Verified

32 suites, `ncurses-editor-tests` 258 (one new: the timer really clears
the message, run by hand through `timer-check!`), `pty-check.py` 61/61 on
its own, no new compiler warnings, and the REPL back door answering an
idle editor both immediately and with no keystroke.

## Still to do

- **Stage 2 is not done.** The outermost command loop still blocks in a
  nested `GMainLoop` per key rather than Gtk's loop dispatching into it.
  What this session removed is the *last thing that stood in its way*: the
  housekeeping that used to ride on a timed read. The inversion itself -
  `*dispatch-event*` set by `main-gtk`, one loop iteration per event
  instead of a `read-key-event` inside a loop - has its pieces in
  `pgtk.sld` already (inert: `*dispatch-event*` is unset, so the key
  handler enqueues exactly as before) and the switch-over is not made.
- **DONE - the terminal's REPL cap, the one poll left, is gone**; the
  terminal's wait is `select` over the keyboard and a self-pipe. See "The
  terminal's wake: landed".
- `tools/pty-check.py` still does not exercise the back door at all: it
  points `XDG_CONFIG_HOME` at an empty directory, so nothing opens a REPL
  and a dead one cannot fail the battery. A check that drives `tools/repl.py`
  against a running editor would have caught this bug.

# Stage 2: Gtk owns the main loop (2026-10-07)

**`gtk_main` is now the outermost loop of the process.** The editor is
started *from inside it*, and every wait the editor makes nests in it.

```
gtk_main
  └ idle callback → command-line-1, event-loop
       └ read-input-event → nested g_main_loop_run
```

Chris asked for this twice: *"the solution is to run a reentrant gtk loop
so you're still waiting in a gtk loop, just not the main loop"* - and that
is exactly what the shape above is. The editor is reentrant (a minibuffer
prompt, an isearch, a yes-or-no question all read keys from inside a
command) and always will be, so the reads nest; the *outermost* loop is
Gtk's.

## What it cost, and what it replaced

`pgtk.sld` gained `pgtk-main-with` - arm THUNK on an idle callback, run
`gtk_main`, leave it when THUNK returns:

```scheme
(idle-add 0 (lambda (data)
              (dynamic-wind (lambda () #t) thunk (lambda () (pgtk-main-quit)))
              #f)
          #f)
(main)
```

and `(schemacs ui platform gtk)`'s `main-gtk` now calls it with what it
used to run in the open:

```scheme
(parameterize ((*current-frame* frame) (*frame-creation-function* gtk-create-frame))
  (pgtk-main-with (lambda () (command-line-1 args) (note-file-read-only! frame) (event-loop frame))))
```

**The `parameterize` encloses the *loop*, not just the setup**, and that is
deliberate: the idle callback is invoked from `gtk_main`, which is called
from inside that body, so the fluid values bound there are the ones the
editor and the REPL see.

Before this, `main-gtk` ran `event-loop` directly and the read made a
`GMainLoop` of its own (`pgtk-wait!`). That is a Gtk loop in every way that
mattered to this editor - it is what let the idle burn be fixed - but
`gtk_main_level` stayed 0, so any Gtk call that wants the main loop running
(a modal dialog, a popup menu, a drag) would have started a second,
unrelated loop rather than nesting in the editor's.

## The inversion I planned and did not do

The plan was an *inversion*: `main-gtk` sets a dispatch hook,
`pgtk.sld`'s key handler calls it when no read is outstanding, and the
command loop becomes one iteration per event instead of a
`read-key-event` inside a loop. **That scaffolding was written, and then
deleted.** Reason: with `gtk_main` owning the process, a key that arrives
while no read is outstanding is simply a key waiting for the next read -
which is what GNU Emacs's `read_char` finds when it looks at the keyboard -
and dispatching it from the signal handler would run a command from inside
a Gtk callback *outside* the command loop, losing `pre-command-hook`, the
redisplay, and the prefix/`this-command` bookkeeping that the loop owns.
The pieces removed: `*dispatch-event*`, its export, `pgtk-main` (nothing
runs the loop without a thunk now), and the dispatch branch in the
`key-press-event` handler, which is back to a plain `pgtk-enqueue!`.

## Verified live (screenshots and the REPL back door)

- **It draws.** `pgtk-write-screenshot!` on a real window: the buffer, the
  mode line (`-:**-  live5.txt  -- L1 C1  (Fundamental)`) and a message in
  the echo area, all correct.
- **Keys work.** `(dispatch-input-event f #x41)` inserts `A`.
- **Timers work with no key.** `(set-message! f "still fine" 0.5)` is gone
  two seconds later, and the read was blocking the whole time.
- **Idle is 0.0%** measured from `/proc/PID/stat` over 10 s - *with* the
  back door answering `(+ 1 2)`, which is the point of the note above.
- **`C-x C-c` on a pristine buffer exits the process**: the `call/cc` in
  `event-loop` is escaped, `pgtk-main-with`'s wind calls `pgtk-main-quit`,
  `gtk_main` returns, the window closes, `main-gtk` returns.
- **The REPL answers from inside a nested read.** With a modified buffer,
  `C-x C-c` puts up `"Save file /tmp/live6.txt? (y, n, !, ., q, or C-g) "`
  - a minibuffer read nested inside the read nested inside `gtk_main` -
  and `tools/repl.py` still answers while it is up.

**Not verified, and named rather than implied:** answering that prompt with
a *real* key. A Gdk event cannot be synthesized from outside, and driving
the window with `wtype`/`xdotool` is the compositor method AGENTS.md warns
about (a silent mis-focus produces a screenshot of another window that
looks exactly like evidence). What that path rests on is the terminal
battery, which answers prompts through the same command loop.

32 suites, `pty-check.py` 61/61 on its own, no new compiler warnings.

## Still to do

- **DONE - the terminal's REPL cap is gone** (it was
  `(repl-open?) (not (repl-wake)) 100` in two places). The terminal's wait
  is a `select` over the keyboard and a self-pipe, and `set-repl-wake!`
  writes the byte through a thunk that writes to a descriptor - which is
  what that shape was chosen for. See "The terminal's wake: landed".
- **`tools/pty-check.py` does not exercise the back door at all** - it
  points `XDG_CONFIG_HOME` at an empty directory, so nothing opens a REPL
  and a dead one cannot fail the battery. A check that drives
  `tools/repl.py` against a running editor would have caught the wake bug
  recorded above.
- Incremental redraw: `render!` still clears the whole surface for a
  keystroke that only moved the cursor.

# The REPL notification, designed into Guile's file (2026-10-07)

Chris's idea, and a better one than what was there: take Guile's
`coop-server.scm` **whole, under its own name**, and design the
notification into it as a hook that could be submitted upstream.

## What was wrong with the old arrangement

`schemacs/repl.sld` *was* `(system repl coop-server)` copied, plus one
line - `(wake!)` after the enqueue. It worked, but the change had no home:
the copy was invisible as a copy, and the one line that mattered looked
like a hack because it was sitting in a file that was supposed to be
project code.

## What is there now

**`schemacs/coop-server.scm`** - upstream's file, verbatim, with two
changes. The diff is checkable:

    diff -u /usr/share/guile/3.0/system/repl/coop-server.scm schemacs/coop-server.scm

and it is exactly: the file header, the module line (`(schemacs
coop-server)` so it does not shadow Guile's), and the two changes below.
Every other line is upstream's, comments included.

1. **The server record carries a `notify` procedure**, given to
   `spawn-coop-repl-server` with `#:notify`, called by
   `coop-repl-server-eval` **after** the enqueue and **outside the
   mutex**. Upstream's polling contract is unchanged - `#:notify` is how
   you know when a poll is worth making, not a replacement for polling.
2. **`poll-coop-repl-server` answers whether it applied anything**, so a
   consumer whose wake is level-triggered can drain the queue rather than
   guess how many items a wake stood for.

Four decisions inside that, each of which is a trap if got wrong, and each
of which is in the docstring rather than in a reviewer's head:

- **Outside the mutex.** `notify` is the caller's procedure; running it
  with the server's lock held deadlocks the moment it touches the server -
  which is exactly what a consumer that drains the queue from its notify
  does.
- **Called with the server.** `spawn-coop-repl-server` starts the
  accepting thread *before* it returns the server, so a notify that wants
  to poll cannot capture it in a closure - there is nothing to name yet.
- **Called from any thread, possibly two at once.** It runs on the accept
  thread for `new-repl` and on a reader thread for `eval`, and nothing
  serialises it. A consumer calling into a GUI toolkit has to use a
  thread-safe post (`g_idle_add` is documented thread-safe) and not touch
  a widget.
- **Never before the enqueue**, which is what makes the wake safe to
  trust: a level-triggered wake cannot miss an operation, because the
  thing it watches is not raised until the operation is on the queue.
  This is the difference between a wake that is *a byte for an enqueued
  item* and a wake that is *the socket being readable* - the latter has a
  real lost-wakeup race, because readable does not mean a whole datum has
  arrived.

**`schemacs/repl.sld`** is now only what is ours: the port file,
`start-repl!`, `repl-open?`, and the wake. It went from ~430 lines to
~230, and with it went the whole `@@` import list - `start-repl*`,
`prompting-meta-read`, `run-server*`, `add-open-socket!`, `close-socket!`,
`guard-against-http-request`, `*repl-stack*` - because that machinery now
lives where it is a copy of something. `poll-repl!` drains the queue:

```scheme
(let loop () (when (poll-coop-repl-server server) (loop)))
```

## Verified

- The REPL answers while the editor is idle, and `tools/repl.py` drives it.
- **Idle CPU 0.0%** measured from `/proc/PID/stat` over 10 s, *with* the
  back door answering.
- `(pair? (@@ (schemacs editor pgtk) *pgtk-running*))` is `#f`: no read
  loop of ours is outstanding, so `gtk_main` is the loop in charge.
- Keys dispatch, `C-x C-c`'s continuation still leaves `gtk_main`, and
  the port file is removed on the way out.
- 32 suites pass; `tools/pty-check.py` 61/61.

## Facts about pipes that cost time to establish

Both of these would silently defeat a self-pipe, so they are recorded
before anyone builds the terminal half:

- **`_IONBF` is not a Guile binding.** Guile's `setvbuf` takes the symbol
  `'none` (with `'line` and `'block` beside it). `(setvbuf port 'none)`
  works; `_IONBF` is the C constant and is unbound.
- **Guile's `(pipe)` gives *buffered* ports.** A `put-u8` on the write end
  goes into the buffer and never reaches the descriptor, so `select` on
  the read end reports nothing - measured. The write must be unbuffered
  (`setvbuf` first) or go to the raw fd, or the waiter never wakes.
- Guile ports are thread-safe (transparently so since 2.2), so an
  unbuffered one-byte write from a reader thread is fine.
- A full pipe blocking its writer is only a hazard when the reader is the
  *same* thread. Here the reader is the main loop, so the write unblocks
  as soon as it drains, and it cannot deadlock.

## Still to do

- **The terminal's notify.** It cannot be given a callback - ncurses has
  no event loop to call back into - so its wake is a pipe the coop server
  writes a byte to, and the terminal's `select` includes it alongside
  stdin. That removes the last poll in the tree: the two
  `(repl-open?) (not (repl-wake)) 100` sites and the cap in
  `read-wait-ms`. SIGWINCH needs no plumbing - `select(2)` is never
  restarted after a signal handler, so it interrupts the wait and
  `getch` with `nodelay` picks up `KEY_RESIZE`.
- **`tools/pty-check.py` does not exercise the back door at all** - it
  points `XDG_CONFIG_HOME` at an empty directory, so nothing opens a REPL
  and a dead one cannot fail the battery. That is how the fluid bug
  survived a "61/61"; a check that drives `tools/repl.py` against a
  running editor is the fix.

# The terminal's wake: landed (2026-10-07)

The last poll in the tree is gone. A terminal front end can be *told* that
the back door has work, the same way Gtk is told, and `keyboard.sld` now
asks for no cap on its behalf.

## What landed

- **`term.sld` owns the wait**: `read-input-event` waits in
  `select {keyboard, wake-pipe}` instead of `timeout!` + `getch`.
- **`install-repl-wake!`**, called by `with-terminal`, makes an unbuffered
  pipe and gives `set-repl-wake!` a thunk that writes one byte to it - the
  terminal's counterpart of Gtk's `idle-add`. The wait drains that byte and
  runs `poll-repl!`.
- **`getch` is now called only because `select` said the descriptor is
  readable**, with `nodelay` set: the byte is already there, and a second
  wait inside `getch` would be a second way to miss the caller's deadline.

Measured at a pty, back door open, nothing typed:

| | HEAD (the 100 ms cap) | now (woken) |
|---|---|---|
| idle CPU | 0.2% | **0.0%** |
| back door answers an idle editor | 0.26 s | **0.13 s** |

**The terminal's poll was cheap** - there is no guile-gi crossing in it -
so what this buys is one fewer moving part in the tree, not a rescue. The
27%-to-0% number in the section above is Gtk's and is a different thing.

## The bug, and why four attempts failed on it

**Guile's `select` answers ONE value: the list of three lists.** Not three
values:

    (select (list fd) '() '() 0)   =>   ((fd) () ())

so a `let` binding of the call holds `((read) (write) (except))`, and every
`(memq fd ready)` against *that* is #f. The read set is the `car`.

That is what broke the earlier attempts, and it explains their shape
exactly: with the ready set never matching, the loop fell through to its
"nothing arrived" answer on **every** call, so the command loop was told
there was no key over and over - which is why eight checks failed at once
rather than one of them going subtly wrong. The spins guard in the code is
what turns that into a spin rather than a hang.

**This is the third time in this file that printed evidence was read for
its gist instead of its shape.** The isolated test printed
`select ((11) () ())`, and that reads as "fd 11 is ready" - which is what
it would have said if the code had been right. Only the editor's own trace,
printing `ready=` and `wake=` side by side, made the mismatch visible.
**Print both sides of a comparison, not the one you expect to be true.**

Everything this file used to say about the tty is still true - `raw!`
clears ICANON, ncurses reads a byte at a time, there is no public "is
anything buffered" call, `select` is on the descriptor `wgetch` reads.
None of it was the fault.

## A correction: `nodelay` does not bound the assembly wait

A lone ESC already in the queue made a `nodelay` `getch` block **1002 ms**
before returning the ESC. The delay wait consults the window's delay only
while ncurses's own buffer is empty (`lib_getch.c:516`); the
sequence-assembly wait is separate and uses `GetEscdelay`, which no window
setting touches.

An earlier note in this file said that wait "cannot fire on the case that
occurs, because what survives in the fifo is only the tail of a *failed*
sequence". That was **wrong**: a fresh ESC straight off the terminal is
itself a prefix, so it fires on the ordinary case of pressing ESC. What
does hold is the other half - a non-empty buffer skips the delay wait
entirely, which is why draining with `nodelay` after a key is cheap.

## A gotcha that cost more than the fix

**`display` is not bound in `term.sld`.** It is `(scheme write)`'s, and
that library imports `(scheme base)`, which does not export it - so a
tracing helper written with `display` died on its first line, inside a
`catch`, and left an empty log file behind, which read as "this code never
ran". `write-u8`, `read-u8`, `char-ready?` and `eof-object?` *are*
`(scheme base)`'s and are fine.

Ask the library rather than assuming, which is one line:

    (module-variable (resolve-module '(schemacs editor term)) 'display)   => #f

## The harnesses this needs, which are still in /tmp

Two Python drivers were written for this and are **not checked in** - they
should be, and each covers a gap `tools/pty-check.py` has by design:

- **A keystroke-level driver**: sends one key, prints the screen, repeats.
  It says *which* key was misread instead of "the last line was not scrolled
  into view", which is the distinction 61 aggregate checks cannot make. The
  headless scenario now matches HEAD key for key.
- **A back-door driver**: opens the REPL, leaves the editor alone, and
  measures idle CPU from `/proc/PID/stat` before and after poking it.
  `tools/pty-check.py` points `XDG_CONFIG_HOME` at an empty directory, so
  nothing opens a REPL in it and a *dead* one cannot fail the battery - a
  probe like this would have caught the fluid bug in the section above, and
  the `select` bug in this one, in one run each.

## The back door's module was the editor's module

Found by driving the terminal's new wake at a pty with a prompt up, and it
is the reason `tools/repl.py -m` could fail "intermittently".

**Guile's REPL reads and evaluates every expression in
`(current-module)`** - `(system repl repl)` does `(eval form
(current-module))` and builds the prompt from the same call. So the back
door's expressions were resolving in whatever module the editor's thread
was nested in at the moment the server's work was resumed. It is one
thread and one dispatch, as Chris pointed out; the variable is not timing
but *nesting*.

Measured, both pokes through the same `poll-repl!`:

| where the thread was waiting | `(module-name (current-module))` |
|---|---|
| at idle, in the read | `(guile-user)` |
| while "Find file:" was up | **unbound** - `module-name` itself was |

The second is `(schemacs editor files)`: a command's interactive
expression is run with `(eval spec module)`, and `eval` binds the module
for the *whole* of that evaluation - which for `find-file` includes its
prompt's read. A library has no `import` to offer, so
`tools/repl.py -m '(schemacs editor xdisp)' ...` worked at idle and failed
while a prompt was up.

**`poll-repl!` pins it now**: `save-module-excursion` around the drain,
with `set-current-module` to `(guile-user)` - where a name like `import`
lives, and what `tools/repl.py`'s docstring already promised. Verified
with "Find file:" up: `(current-module)` is `(guile-user)`, `import` is
visible, and `-m` works.

**Not a leak in the command machinery** - that was the first guess and it
was wrong, measured: `eval` restores the module when it returns
(`eval leaked the module? #f`). The machinery is sound; the back door was
reading the thread's dynamic state rather than having a namespace of its
own. Pinning is the whole fix, and it is the same shape as the file's
earlier lesson about fluids: **state that belongs to the process should
not be inherited from whatever dynamic extent happens to be current.**

The nested read is also now verified on the terminal for the first time:
with a minibuffer prompt up, the back door still answers, in 0.13 s, at
0.0% CPU.

# The mouse: clicking a window selects it (2026-10-08)

Chris: *"in real emacs if I click in a window in gui mode, it activates
that window. in schemacs I have to C-x o to get to the right window."*

Emacs's chain is short: `(global-set-key [down-mouse-1] #'mouse-drag-region)`
(`mouse.el:3781`), no motion ⇒ `mouse-set-point` (`mouse.el:1586`) ⇒
`posn-set-point` (`subr.el:2013`), which is `(select-window (posn-window
position))` and `(goto-char (posn-point position))`. That is the whole of
"the window I clicked in becomes the selected window".

## What landed

- **`subr.sld`** — `nth` and the `posn-` cluster: `event-start`,
  `event-end`, `posn-window`, `posn-area`, `posn-point`, `posn-x-y`,
  walking the event list `(SYMBOL (WINDOW POS-OR-AREA (X . Y) TIMESTAMP))`
  exactly as `subr.el` does.
- **`mouse.sld`** (NEW, mirrors `mouse.el`) — `posn-set-point`,
  `mouse-set-point`, `mouse-drag-region`, `mouse-drag-track`, `mouse-key?`,
  and mouse.el:3781's own binding line. **`posn-set-point` is `subr.el`'s
  but lives here**, because it needs `select-window` and `goto-char` and
  `(schemacs editor frame)` imports `subr`: a definition in `subr.sld`
  could not reach either. Named in both files.
- **`xdisp.sld`** — `posn-at-x-y` (`keyboard.c:13009`, which is
  `make_lispy_position`) and `buffer-posn-from-coords` (`xdisp.c`). The
  row walk is the renderer's own helpers (`line-string-at`,
  `line-display-texts`, `%window-line-slices`, `line-next-start`), so the
  answer agrees with what is on the screen; a hand-written second walk
  would be free to disagree.
- **`keyboard.sld`** — `*last-read-event*`: the display's *own* event
  value, carried to the command, because a key path element cannot hold a
  position. Emacs's `last-input-event` exists for the same reason.
- **`pgtk.sld`** — `button-press-event`/`button-release-event` on the
  drawing area, tagged into the queue, and the decode that answers
  `down-mouse-1`/`mouse-1`.

**Point moves on the *press*, not on the release.** `mouse-drag-track`
calls `mouse-set-point` in its `let*` - `mouse.el:1939`, "let's jump to
the place of the event, where things are happening" - before it reads a
single motion event. So the click needs no motion machinery at all, and
that is why this was worth doing before the drag.

## The five faults it took, four of them mine

1. **`event:get-coords` used and never imported.** The first click raised
   `Unbound variable` *inside the signal handler*, where Gtk swallows it:
   a click that did nothing, with no message. The tree's recurring
   missing-import class - and the compiler had said so, in a warning I
   read past while chasing parentheses.
2. **Two values bound where it returns three.** `gdk_event_get_coords`
   returns a boolean and two out-parameters, the same shape as
   `event:get-keyval` (which the tree binds as `((_ keysym) ...)`):
   binding two put the boolean in X and made `round` raise on `#t`.
3. **The event mask was `12`.** I recalled `GDK_BUTTON_PRESS_MASK` as
   `1 << 2`; the header says otherwise (`gdktypes.h:436`):

       GDK_POINTER_MOTION_MASK = 1 << 2      GDK_BUTTON_PRESS_MASK   = 1 << 8
       GDK_POINTER_MOTION_HINT_MASK = 1 << 3 GDK_BUTTON_RELEASE_MASK = 1 << 9

   So `12` asked for *motion* and the press went elsewhere. The symptom
   was **nothing at all** - no handler, so no error to see - which is the
   worst kind, and it is why the fix was found by asking the editor what
   the widget had selected (`widget:get-events` → 768, and the GdkWindow's
   own mask) rather than by reading anything.
4. **The hand-over path.** `*dispatch-event*` *is* set, so an idle editor
   dispatches an event straight from the signal handler and never goes
   through `read-key-event`. `*last-read-event*` was set on two of the
   three paths an event can take, so a click arrived at the command as
   `(down-mouse-1 (FRAME))` - the shape for a *frame* event - and
   `posn-set-point` selected the window the editor was already in. No
   error, no message, no change: selecting the window you are in is not an
   error.
5. **`main-loop:unref` used at `pgtk.sld:1018` and never imported**
   (pre-existing): the nested-loop teardown would have raised the first
   time that branch was taken.

## The lesson worth keeping

**I verified through `dispatch-input-event`, the one path that already
worked, and treated it as proof.** A test that drives only the path you
just fixed says nothing about the paths it bypasses - and four of the five
faults above were on paths my "end-to-end" test never took. What actually
found them was asking the *live* editor questions (`widget:get-events`,
`(*dispatch-event*)`, `(widget:get-queue)`) in a `broadwayd` display, and
temporarily logging to a *file* rather than to the echo area, which only
ever shows the last message and so cannot say what a click did.

## The drag, the region, and a click below the text (same day)

- **Motion events.** `pgtk.sld` asks for `GDK_POINTER_MOTION_MASK` beside
  the button masks (`768 + 4`), queues them tagged, and decodes them as
  `mouse-movement`.
- **`mouse-drag-track`'s real loop.** The mark goes down with the *press*,
  every motion event moves point (`mouse--drag-set-mark-and-point`,
  `mouse.el:2044`, ported verbatim, including the two `eqv?` cases that
  stop a drag back over its own start turning the region inside out), and
  the release leaves the region active. The motion's *position* is read
  from `*last-read-event*`, because `read-key-event` answers only the key -
  which is what that parameter was added for.
- **`mouse-start-end`** and **`mouse-set-region`** are ported. Mode 0 only:
  every event this tree makes is a single click, and a click count needs a
  clock.
- **A click below the text** now answers the end of the last line, as
  Emacs's `buffer_posn_from_coords` does by walking the rows it can and
  stopping at the last one. It used to answer `#f`, which left point where
  it was. And **motion is gated on `*track-mouse*`** (below), which is a
  fault worth its own line:

## The sixth fault: motion is not an event unless `track-mouse` says so

`xdisp.sld` now has `*track-mouse*` - GNU Emacs's `track-mouse`, a C
variable of `xdisp.c` - and it is *whether pointer motion is an event at
all*, not which events to look at. `mouse-drag-track` binds it to t around
the tracking loop; `pgtk.sld`'s motion handler asks it before queueing
anything.

Connecting the motion signal unconditionally, which is what this did
first, makes **every pass of the pointer over the window** queue a
`mouse-movement` that the command loop has nothing bound for:

    ; undefined key : ("mouse-movement")

Emacs does not have this failure because its display never makes the event
in the first place. A front end that reports everything and filters later
would have the same bug in a different place.

Verified headlessly - the four cases of the drag rule, which are what the
`eqv?` cases exist for:

    press at 10:    mark=10 point=10   drag to 20:  mark=10 point=20
    drag back to 5: mark=10 point=5    drag to 25:  mark=10 point=25

and a click's posn still names the window it landed in and the character
under it.

Still named: the click count (double and triple click), `mouse-face`, the
mode-line and scroll-bar areas beyond `'mode-line`, and
`mouse-autoselect-window` (nil in Emacs by default).

# The back door's session has the editor's names (2026-10-08)

Chris, first use of `se --repl`:

    ./se --repl
    scheme@(guile-user)> (find-file "README.md")
    ;;; socket:9:1: warning: possibly unbound variable `find-file'
    Unbound variable: find-file

"as far as I see, `--repl` is broken" - and the *door* was fine: the socket,
the port file, the prompt, the evaluation in the editor's own process all
worked. What was missing was the module's contents.

## The departure, and what was done

GNU Emacs has **one obarray**, which is why `find-file` is reachable from
`eval` inside a running Emacs. This tree's names live in one library per
Emacs file and the session is pinned to `(guile-user)` (`poll-repl!`), which
has none of them - so `find-file` had never been bound there.

`start-repl!` now runs **`open-editor-namespace!`** (`schemacs/editor/loadup.sld`
since 2026-10-08, `schemacs/repl.sld` before that - the init file wants the
same names, see the startup-screen section), which evaluates one `import`
form in that module listing every `(schemacs editor ...)` library. The list
is written out (the tree's root is not a thing a running editor knows), so
it can go stale - and **`schemacs/editor/loadup-tests.scm` is what
notices**: it walks `schemacs/editor/*.sld` and fails on a library that is
neither in the list nor in `editor-excluded-libraries`. Verified by
removing one entry: the test names it.

**The two exclusions are the toolkit bindings** - `term` (guile-ncurses) and
`pgtk` (guile-gi). An editor has one loaded and must never need the other,
which is what `schemacs/main.scm` already says about the front ends; and for
a terminal editor the Gtk bindings are not merely wasteful but absent. A
session that wants them can `(import (schemacs editor pgtk))` - which it can,
because the module it is in now has `import`.

## The banner

Chris: *"if the repl is connected to foreign process repl, why do I get the
guile copyright message?"* - and then *"can we easily suppress it?"*.

It is the **editor's** Guile printing it: `run-repl*` (`system/repl/repl.scm:158`)
prints the copyright notice, the warranty line and "Enter `,help' for help."
when the session is the outermost one on the *server process's* stack, and
`start-repl*` is reached from `poll-coop-repl-server` on the editor's main
thread. So it is a greeting for a program the user did not start, and no
client can suppress it from its end - `tools/repl.py` had been reading past
it. `poll-repl!` now binds `%inhibit-welcome-message` (the parameter Guile
provides for exactly this) around the drain, because that is where the
session starts.

It is *evidence*, not a symptom: a client that shows the banner is talking to
the other process. Nothing in `se --repl` prints it.

## A check, because the battery had none

`AGENTS.md` named this gap twice - "`tools/pty-check.py` does not exercise the
back door at all... a *dead* one cannot fail the battery", "a check that
drives `tools/repl.py` against a running editor would have caught the wake
bug". It now does: **`back-door`**, with `drive`'s new `during` hook so the
editor can be poked while it is still running. It asserts three things, each
of which has been wrong: that an expression using the editor's names
evaluates at all, that it evaluates *in the editor* (it answers the editor's
own file name), and that the first thing a client hears is the prompt and not
Guile's banner - read **raw**, because `repl.py` deliberately strips the
banner. Both failure modes were reproduced by disabling their fix, and the
banner one has to be the *first* connection: the banner is printed only when
the session is the outermost on the stack.

## Found while doing it

- **A bare `--repl` picks the newest editor that answers, and a stale one
  answers.** Eighteen live editors from a day's testing were holding port
  files (198 files total in `$XDG_RUNTIME_DIR`, eighteen with a live pid),
  each running the code of *its* session. An editor from this morning is
  where a fix appears not to work. Named in the back-door section; the
  leftovers were killed and the dead port files removed.
- **The `overrides core binding 'map'` warning a session can print is
  pre-existing** and not the import list: `se` itself imports
  `(except (scheme base) error raise)` into `(guile-user)`, and Guile defers
  that warning until the shadowed name is *first looked up*. Measured: the
  editor's stderr at startup is empty, the warning arrives the first time a
  session mentions `map`, and `for-each`/`map`/`assoc` from `(scheme base)`
  are the same procedures as the core ones (which is why `se` only excludes
  `error` and `raise`).
- **The Gtk back door segfaults under `broadway` with the current tree** -
  reproduced with the *legacy* entry point, and with `repl.sld` reverted to
  `HEAD` and `~/.cache/guile/ccache` cleared, so it is not from this change
  and not the launcher. It is not broadway alone either: an editor left
  running since 10:53 answers `(+ 1 2)` and survives, and Chris's own
  `./se -w` (real display) served a session and stayed up. So it is narrow -
  broadway plus something that landed today - and **not diagnosed**: there is
  no `gdb` or `strace` here, and the log holds only the pre-existing
  AT-SPI and `Gtk-CRITICAL` noise. Worth chasing with a real debugger; the
  terminal path (and so the new check) is unaffected.

Still open: the namespace is imported **as the door opens**, so a running
editor gets it when it is restarted, like every other change in this tree.

## The startup screen (2026-10-08)

Chris: *"on startup schemacs searches for a file splash.txt on your load
path. if it finds it, it will be the opening screen if there are no file
arguments. If there are file arguments, the screen will be split and it
will be the lower screen. Like emacs it will be a special read-only buffer
that if you hit q it will close the buffer. Similar to emacs, if your init
file has this in it: `(set! inhibit-startup-screen #t)` then the splash
screen will never come up."*

All of it is `schemacs/editor/startup.sld`, which is `startup.el`'s file,
and the shape is Emacs's (`normal-splash-screen` `:2372`,
`display-startup-screen` `:2724`, the call at the end of `command-line-1`
`:3125`): the buffer is read-only with a map of its own whose `q` leaves,
`goto-char (point-min)`, and **`display-buffer` when the command line named
files against `switch-to-buffer` when it did not** — which is exactly the
split-below-the-file behaviour asked for. The buffer is `*Schemacs*`
(Emacs's is `*GNU Emacs*`) and `exit-splash-screen` is `quit-window`.

**The text is a file, and that is the one departure of substance**: Emacs's
splash is Lisp that builds its own text. `splash-file` looks on the load
path, first for `splash.txt` (a user's own) and then for
`schemacs/splash.txt` (the copy the tree ships, beside its libraries —
Chris committed one, `a097a69`) — `locate-file-internal`, which is
`lread.c`'s and already ported.

**The init file is now *given the editor's names*.** `(set! inhibit-startup-screen
#t)` cannot work otherwise: the init file is loaded into `(guile-user)`,
which has none of the editor's names, so the variable was unbound. So the
list that `repl.sld` was carrying moved to **`schemacs/editor/loadup.sld`**
— `loadup.el`'s file, "the file that loads the editor" — and *both* callers
use it: the back door and `load-init`. That is the same property Emacs's
init file has ("it runs with all of Emacs's Lisp to hand"), which the
comment in `load-init` had claimed in as many words while not doing it.

### Three departures this turned up, all fixed

1. **`note-file-read-only!` tested the buffer's flag; Emacs tests the
   file.** `after-find-file` says "Note: file is write protected" of a file
   that is not writable and makes the buffer read-only *because* of it. The
   startup screen is read-only and visits nothing, so the front end's call
   announced "Note: file is write protected" about it. It asks
   `file-write-protected?` of `buffer-file-name` now — and a fileless
   buffer says nothing, which the test in `ncurses-editor-tests.scm` now
   checks (the old one set the flag on a fileless buffer and expected the
   message).
2. **`quit-window` on a frame's only window buried the buffer and left the
   window showing it**, so `q` in Dired, the Buffer Menu and the startup
   screen looked like it did nothing — a departure this file already named
   ("so the dired buffer being buried shows something else. Ours leaves it
   showing the buried buffer, which is why `q' in dired looks like it did
   nothing"). Emacs's `quit-restore-window` ends
   `(set-window-buffer window (other-buffer ...))`; ours does
   `(switch-to-buffer (other-buffer buffer))` for that case now.
3. **The whole tree did not compile.** See the gotcha below.

### Two harness changes

`tools/pty-check.py`'s editors are given an init file saying
`(set! inhibit-startup-screen #t)`: the tree ships a splash, so every check
that starts the editor on a file would otherwise have a split screen it is
not about — and, usefully, every check now loads an init file, so the path
that gives the init file the editor's names runs 63 times a battery. The
`splash` check passes its own `config=` with no init file in it.

And `drive` now passes **`-L REPO` and not `-L .`**: `locate-file`'s rule —
the C's own, `openp` — expands a *relative* load-path entry against
`default-directory`, which by then is the *visited file's* directory, so
with `-L .` the tree's own `schemacs/splash.txt` was invisible. `se` has
always put the absolute tree on the path, so only the harness was affected
— but it is worth knowing before writing the next load-path search.

## `--remote`, and the redisplay the back door was missing

Chris asked for `-r`/`--remote[=PORT] FILE...`: `emacsclient` - the files
go to a *running* editor's `find-file` and no editor is started - and
warned *"in this case, I don't think copying emacs will be a win"*, which
is how it is written: no `server.el` protocol, no `-dir` handshake, no
`find-file-noselect`-plus-window dance. One `(find-file "FILE")` per name,
sent as text and read by the editor. What the client does decide for
itself is in the back-door section above (the client's directory for a
relative name, and reading answers by the prompt rather than by a trailing
`>`).

Writing it found a **departure the back door had all along**: nothing
repainted. Measured - `se --remote FILE` opened the file, `(buffer-list)`
had it, the *screen* still showed the previous buffer, and it stayed that
way until the next keypress. `poll-repl!` redraws now
(`redisplay-frames!`, and only when it ran something). This is not a
convenience: in Emacs the main loop redisplays as it processes input, and
the socket is input - here the command loop's redisplay is *after a
command*, and a back-door expression runs from the wait between them. It
explains why `tools/repl.py '(find-file ...)'` has always needed a
following `(render! ...)`, and it means a session that only *reads* the
editor no longer has to know that the display is stale.

`loadup-tests.scm` (the namespace and the library list) and
`repl-client-tests.scm` (the port files, the answer reader, the expression
`--remote` sends) are the unit tests; `tools/pty-check.py`'s `back-door`
check is the end-to-end one, and it now runs `./se --remote` against the
editor it has open. Verified to fail with each fix reverted: the namespace
(the session's names), the banner, and the repaint - each with its own
message.
