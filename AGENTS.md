This project is taking the schemacs emacs editor project, and trying to turn
that half done project into a real editor. When I picked it up a lot of the 
machinery was in place, but it wasn't actually an editor. It would start
up a gtk window with a couple of GtkTextAreas, but didn't actually do anything.

We are reimplementing emacs in guile scheme. The general plan is to plan new features,
translate real emacs source code into scheme, and put that ported code into
files with the same name as in emacs. e.g. intervals.c in emacs became intervals.sld
in this project. Also, each function in the same file should be kept in the same
order as emacs. Each function in emacs should be ported with the same name to the 
same file here, generally with the same parameters too. And it should be in the same 
subdirectory too. e.g. emacs lisp/progmodes/cc-engine.el should be in 
schemacs/progmodes/cc-engine.scm. lisp/font-lock.el should be in schemacs/font-lock.scm
src/frame.c should be in schemacs/frame.scm ... the lisp/emacs-lisp is mapped to schemacs/core
the exception is files that are specific to either tty or gtk interfaces
they will go in either ui/gtk or ui/tty
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
it is built up from exactly the same primitives. If this results in a ballooning
amount of work, check back with the user to approve the scope.

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

If you implement a package that is not part of core emacs, it will go
into schemacs/external.  Put a note in the package of the original
github (or elsewhere) location of the original emacs compatible package.

If you get into a mess with either bad behavior or super large functions,
always check yourself... does real emcas have a function this messy or this big?
Sometimes it does, and it is what it is. But sometimes you make a mess of it
and try to patch it when you should go back to emacs itself and start afresh.

If our behavior differs to real emacs, don't just figure it out empirically,
look at the emacs code to find out definitively the rule.

If Emacs implements an algorithm in several functions, you should too. Don't
try and mash it into one.

If you're told to implement an emacs feature, but you think you can see
a better way of doing it... don't... at least not without asking.
We are trying an exact replica of emcacs right down to the algorithms.
Follow emacs way anyway.

If you find an emacs function that uses a primitive that we don't have.
Don't try and paper over it by getting around it. It's your job to find that
primitive, port that primitve and make sure our entire code base uses that
primitive the same way emacs does.

I don't even want to see an emacs function refactored without a good reason.
I want to see every function with the exact same shape as emacs, same
args, same structure, same loops, same variables, same recursion, same
number of functions, same everything. Of course this is scheme rather than
lisp, so there will be some deference to it being a different language, 
but there should be very minimal departures from emacs algorithms.

If you either make, or find a departure from real emacs when working
on this project, put as much information as possible in the
DEPARTURES.md file so that we can return to this work later.

**The convention, settled 2026-11-07: dynamic variables are parameters,
and their names are `*...*`.**

The editor's dynamically bound variables are SRFI-39 parameters - made
with `make-parameter`, read as `(*name*)`, bound with `parameterize`.
A parameter's name carries an asterisk at each end, so a reader can see
that its value may change under the code reading it. The stars are this
tree's, in the Common Lisp tradition; they are not part of Emacs's name.

The exceptions, where the name is the interface:
- `current-prefix-arg`, `current-display`, `replace-overlay`,
  `isearch-overlay`, `isearch-lazy-highlight-overlays`,
  `xterm-query-timeout`, `xterm-max-cut-length` keep Emacs's bare name;
- `MODE-hook`, one per `define-minor-mode`, is generated.

Everything that is *not* dynamically bound is a plain `define` and takes
no stars: constants, objects built at load time (coding systems, keymaps,
faces), value aliases, and process-global registries, caches and
counters. The test for which one a variable is: does the ported Elisp
`let`-bind it? If it does, it is a parameter; if it is only ever read
and `setq`-ed, it is a plain variable.

That supersedes "we don't use parameterize or fluid-let" above: the
editor's dynamic state is parameters and cannot be anything else.
Emacs binds a value around a thunk the caller wrote - `delay-mode-hooks`,
`called-interactively`, dired's `dired-map-over-marks` - and a thunk has
no argument to receive it, so no amount of parameter-passing reaches the
reader. `fluid-let` is deleted (2026-11-07): it was a second spelling of
`parameterize` for plain variables, and nothing used it.

You need to be aware of the range of differences between elisp and scheme.
t in elisp is #t in scheme. nil in elisp might be '() or #f depending
on the circumstances.

Of course, we don't want to fully port code that exists in guile itself or
a guile library we can download. In that case the answer is to integrate core
guile functions and/or find the right library. When I say port every primitive
I mean in functionality, occasionally that porting might mean substiuting 
functions that already exist in scheme or guile.

If code you are writing uses an elisp macro that doesn't exist in guile,
such as "unless" or "when" or whatever it might be, don't just write
something else that does the same thing, port the elisp macro into this code
base. If it's a macro that's widely used, it should go prefereably in the
file where elisp defines it, or some central location. If an elisp macro
conflicts with core guile, like for example cond, rename the elisp version
with an -e suffix, so the emacs port of cond becomes cond-e. you only should
to use cond-e or when-e or unless-e if it would yield a different 
result to guile cond, when or unless. Become familiar with the difference
(I believe the default result is different). Prefer a guile construct
where it's just as simple as an elisp construct. Prefer begin to progn
for example.

If you find yourself trying to debug code, you're probably better off looking
at the emacs code to see how you departed from it, rather than trying to reason
about why it doesn't work. The emacs code works, so if you ported it faithfully,
yours will work too. Where you get bugs is mostly where you try to wander off
your own way. Many times you found that you were chasing rabbit holes of bugs
but when you read the emacs source you landed it first time.

Do NOT name variables with a "*" in the name, unless that occurs in emacs
which I don't think it does.

You will most likely find full emacs sources at @../../GITE/emacs/

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

if emacs has an interesting macro or syntax-rules we should implement it,
so as to keep the same shape as emacs code. make a schemacs/core/syntax-macros.scm 
for syntax.

If you implement a feature that emacs has attached to a menu or menu bar,
or mode line, make sure you also attach it to the menu, bar or modeline.


- `tools/syntax-check.scm` — after ANY scripted edit to a machinery
  `.scm` file, run `guile -s tools/syntax-check.scm <files>`: it runs
  Guile's own reader over the files and reports read errors with the
  reader's file:line:col (exit 1 on failure). Catches the
  paren/quote/docstring-corruption class of bug at the edit site.

# Handoff — state of the buffer-menu work (2026-09-27)

## Where we are

The layout plan (LAYOUT-PLAN.txt) is essentially executed: `apps/ncurses-editor.sld`
(3,471 lines) has dissolved into `schemacs/editor/*.sld` plus
`schemacs/ui/ncurses/ncurses.sld`. One library per mirrored Emacs file:

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
1. `(schemacs buffer)` registry (buffer-list, get-buffer-create, kill-buffer, …)
2. `keyboard.sld`'s `lookup-keymaps` consults the buffer-local keymap before the global
3. `ncurses.sld` imports the binding-carrying libraries

**The RET binding** stays as it is: RET is the *event* control-M (13), not
the character `#\return` — a terminal sends byte 13, which is that event,
and that is exactly Emacs's binding (in Emacs `(kbd "RET")` and
`(kbd "C-m")` are the same key event).

*(Superseded 2026-10-09: the key path this note was written about — a list
of modifier symbols and a character — is gone. A key is an event or a
vector of events now, as it is in Emacs; see "the keymap's key currency"
in the plan of that name.)*

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
  (`abbreviate-file-name`, the other half of that line - the `~` in the
  prompt - was still missing when this was written; it landed with the
  dired pass and was made faithful in the 2026-10-09 pass below, which is
  where the prompt got its `~/`.)
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
- Wiring: build.scm, Makefile, both platform files (`(only (schemacs replace))' for the M-% bindings), tools/run-suites.py gained
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

      for f in schemacs/**/*.sld; do guile -L . -c "(compile-file \"$f\")"; done

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
- Run with `guile --no-auto-compile -L . -s <file>`, `GUILE_WARN_DEPRECATED=no`.
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
  `(schemacs keyboard)` and not in minibuffer.sld.

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
`(schemacs command)' import did not have it - the missing-import
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
- tools/syntax-check.scm re-execs itself with : Guile's default reader
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
     (schemacs buffer)      <- imports engine
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
`test/buffer-text-test.scm` (58 tests). Wired into `build.scm`,
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

Tests: `test/files-test.scm` (13), wired into
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
`it is a minimal environment, and `(+ 40 2)' answered **"Unbound
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
being one key, measured: `(event-convert-list '(control ?m))` is 13 and
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

*(Superseded 2026-10-10: that staged build - a `.guile-cairo/` directory
under the tree, put on the load path by `se` and by this runner - is
gone. A guile-cairo newer than 1.11.2 is **installed** now, into the
prefix `guile-config info prefix` names, so Guile's own load path finds it
and `se` knows nothing about cairo; `schemacs/main.scm`'s `check-cairo!`
says what is missing and how to install it when the Gtk front end asks
for a library that is not there.)*

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
function), and `string-match` comes from `(schemacs search)`.

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

   *(Superseded 2026-11-19: `detect_coding` is ported as
   `detect-coding-bytes` (`coding.scm:1738`), `files.scm`'s
   `coding-system-for-file` calls it, and the corpus is **20/21** with
   only `iso-2022-jp` left. See "The read-path coding detector, closed"
   at the end of this file - the note above stayed wrong for over a
   month and sent a session looking for work that was already done.)*
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
`(schemacs buffer)` imports `(schemacs frame)`, so `frame.sld`
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
the tree (`for f in schemacs/**/*.sld; do guile -L . -c "(compile-file \"$f\")"; done`)
before a battery run, and after editing anything, so that the cache is
newer than every source. A scripted edit-and-compile can still lose the
race on mtime *granularity* - the write and the compile inside one second
- which shows up the same way.

**And do not edit the tree while a battery run is in flight.** The battery
takes ten minutes and starts a *fresh* editor per check, so a `.sld` edited
half way through is newer than its `.go` for every check after that, and
each of them reads the note as part of its screen. Measured, on the
`abbreviate-file-name` pass: editing `files.sld` mid-run produced
**53/65**, with failures in eight checks that have nothing to do with the
edit - `replace-string`, `dired`, `quoted-insert`, `find-file-read-only`,
`revert-buffer` among them - and one of the messages carried the evidence
instead of the thing it was testing:

    with overwrite mode off, X did not insert before abcdef
      (screen ';;; note: source file .../files.sld;;;    ')

Recompiling the tree and running the battery again - on a tree that is then
left alone - is the whole cure.
**A scattered, cross-cutting failure set is this, or load, before it is the
code** - and the note names itself if you read the screen the check printed.

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

> **SUPERSEDED ON 2026-10-31 - read the names below, not the ones quoted
> around them.** The door moved to `(scheme-utils repl server)`, and what was
> left in `(schemacs repl)` was a facade: it imported the door's procedures in
> order to export them again, under renames (`repl-open?`,
> `remove-repl-port-file!`) and behind a wrapper (`start-repl!`, which takes a
> port), plus a *second* pair for the wake - `repl-wake`, `set-repl-wake!` over
> a private variable, and an adapter to bridge the arity. That library now
> exports **nothing**: it is the settings (transport, directory name, module,
> the before/after hooks) and is imported for its effect. The names its callers
> use are the door's own - `repl-running?`, `repl-unpublish-port!`, `repl-wake`,
> `repl-wake!`, `start-repl!`, `poll-repl!` - imported from the door. The two
> `module-ref` reaches into it that this ambiguity produced (`main.scm` imported
> `remove-repl-port-file!` and then looked it up by name 200 lines later, and
> did the same for `start-repl!`) are gone with it. The init file's import is
> `(import (scheme-utils repl server))` now.
>
> **AND THE TRANSPORT IS A UNIX SOCKET, WHICH IT ALWAYS SHOULD HAVE BEEN.** The
> port file, `tools/repl.py` and `--repl=PORT` are gone. The door is at
> `$XDG_RUNTIME_DIR/schemacs/<instance>.sock`, so listing that directory lists
> the running editors, a stale endpoint is told from a live one by CONNECTING,
> and there is no port to write, read, or leave behind. The instance is
> `SCHEMACS_INSTANCE`, or the pid - one editor, one door, and the pid is what
> kept two of them off one path in the port file's day too. A bare `se --repl'
> still means the NEWEST editor that answers; `--repl=NAME' asks for one by
> name, which is the thing a path buys and a port could not. `SCHEMACS_REPL' is
> a FLAG now (a name is `SCHEMACS_INSTANCE`'s business), and `--server',
> `--repl' and `--remote' take a NAME where they took a port - refused if it has
> a `/` in it, because the name is a file name in the runtime directory. The
> client half of this file's subject is `(scheme-utils repl client)`'s, and
> `se --repl' keeps only the policy: which editor a bare `--repl' means.
>
> **`tools/repl.py' is deleted**, and `repl' (installed from scheme-utils) is
> what replaces it: `repl -e EXPR NAME' for one expression, `repl NAME' for a
> session, `repl -p PATH' when the path is known. Everything AGENTS.md says
> about `tools/repl.py' below was measured with that tool and holds for this one.
>
> **AND `repl-eval' HAD TO CLOSE ITS SOCKET.** A program serves one client
> session at a time, and the day `se --remote FILE' was followed by `se --repl'
> against the same editor, the second client was accepted and then never
> greeted: the session `--remote' left open had the door's reader parked on it.
> `repl -e' reported "nothing is answering for NAME" and exited 2, and
> `se --repl' hung with no banner - for the *shared* client, which is fixed
> there rather than here.
>
> **And the wake taught us why a host's callback may not raise.** The adapter
> read the front end's wake with `(%repl-wake)` - applying the variable, which
> holds the thunk - instead of `(repl-wake)`, so it called the thunk and then
> applied what the thunk returned. That raise happened on the coop server's
> *reader* thread, which died: the door then answered exactly ONE expression per
> connection and never read another line, keystrokes included, and nothing in
> that symptom pointed at a wake. `(scheme-utils repl server)`'s `wake!` now
> guards the host's wake and reports it, so this cannot happen to any host
> again. See `guile-dead-thread-is-silent` in the memory index for the general
> shape: a Guile thread that dies says so on stderr only.

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

The second is `(schemacs files)`: a command's interactive
expression is run with `(eval spec module)`, and `eval` binds the module
for the *whole* of that evaluation - which for `find-file` includes its
prompt's read. A library has no `import` to offer, so
`tools/repl.py -m '(schemacs xdisp)' ...` worked at idle and failed
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
  `(schemacs frame)` imports `subr`: a definition in `subr.sld`
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
since 2026-10-08, `schemacs/repl.sld` before that - and it is the *back
door's* alone: an init file imports what it needs, see the startup-screen
section), which evaluates one `import`
form in that module listing every `(schemacs editor ...)` library. The list
is written out (the tree's root is not a thing a running editor knows), so
it can go stale - and **`test/loadup-test.scm` is what
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

**The init file imports what it needs, which is how a name is reached
here.** `inhibit-startup-screen` is `startup.el`'s variable (`:68`), so it
is in `schemacs/editor/startup.sld`, and an init file that wants it says

    (import (schemacs startup))
    (set! inhibit-startup-screen #t)

which is Emacs's `(require 'startup)' and `(setq ...)` in the same two
lines.

**I first did it the other way and it was wrong.** `load-init` imported
*every* editor library into the user's module (the `open-editor-namespace!`
call, still in `schemacs/editor/loadup.sld` for the back door's sake) so
that the bare second line alone would work, on the argument that Emacs's
init file has one obarray to reach through. Chris: *"I never said 'with no
import' ... It's a given that you have to import whatever feature you want
to interact with ... have you fucking stick every bloody variable in the
one bloated massive file, just to stop people needing to import things?"*
The standing order settles it: a name lives in the file its Emacs source
lives in, and the way to it is an import - so the call is gone from
`load-init`, and the docs, the tests and the harness all use the two lines
above.

### Four departures this turned up, all fixed

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
4. **An init file's error was invisible.** `load-init`'s handler reported it
   with `display` to stdout - and on stdout is exactly where the *terminal*
   front end hides it: the text goes to the normal screen and ncurses then
   switches to the alternate one, so it is unseeable until the editor
   exits. Measured while checking the namespace call: with it removed, a
   user's `(set! inhibit-startup-screen #t)' fails and **nothing appears** -
   the feature just seems not to work. It is said in the echo area now as
   well, where a frame is already current, and the text is put together the
   way `main.scm`'s `condition-text' does it: measured, an unbound variable
   raises `(unbound-variable (#f "Unbound variable: ~S" (this-is-not-bound) #f))`,
   so the raw irritants read `#f Unbound variable: ~S #f' and never name
   the variable. The echo area says
   `error: init file PATH: Unbound variable: this-is-not-bound' now.

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

# `C-x b` — switch-to-buffer, and the two seams it crossed (2026-10-09)

Chris: *"For now I want you to implement C-x b, switch-to-buffer. Look at
emacs source code as usual"*, then *"finish it"*. It is in, and the two
bugs under it are the interesting part.

## What landed

| Emacs | here |
|---|---|
| `switch-to-buffer` (`window.el:9581`), its docstring and its `"B"` interactive spec | `window.sld`, a `define-command`, bound to `C-x b` (`subr.el:1746`) |
| `read-buffer-to-switch` (`window.el:9485`) | `minibuffer.sld` — see the placement note below |
| `window-normalize-buffer-to-switch-to` (`window.el:9508`) | `window.sld` |
| `read-buffer` (`minibuf.c:1522`), `internal-complete-buffer` (`:2156`) | `minibuffer.sld` |
| `complete-with-action` (`minibuffer.el:232`), `completion-table-with-predicate` (`:467`), `internal-complete-buffer-except` (`:4211`), `minibuffer-with-setup-hook` | `minibuffer.sld` |
| `buffer-name-history` (`minibuf.c:2515`), `read-buffer-function` (`:2544`), `read-buffer-completion-ignore-case` (`:2559`) | the first is a history record in `minibuffer.sld`; the other two are `minibuf.sld`'s |
| `apply-partially` (`subr.el:129`) | `subr.sld` |
| `minibuffer-complete-and-exit` (`:2087`), `completion-complete-and-exit` (`:2113`), `completion--complete-and-exit` (`:2128`) | `minibuffer.sld`, as the three functions Emacs has |

**Two placements are departures, both forced by the import graph and both
named in the source.** `read-buffer-to-switch` is `window.el`'s but needs
the minibuffer and `internal-complete-buffer-except`, and `window.sld` is
*below* `minibuffer.sld` — so it lives in `minibuffer.sld` and `window.sld`
asks for it through `*read-buffer-to-switch*`, the way a front end installs
`*frame-creation-function*`. `*confirm-nonexistent-file-or-buffer*` and
`confirm-nonexistent-file-or-buffer` are `files.el`'s and **moved down**
into `minibuffer.sld` for the same reason (`files.sld` is above it), which
is what `*minor-mode-alist*` did. Its default was `#t` here with a comment
claiming that was Emacs; Emacs's is `after-completion`, and the difference
is visible — a name typed out in full and RET'd once is accepted without a
question.

## The bug Chris hit: `Wrong type argument: #<<parameter> ...>`

Reported as the error text alone, reproduced in a pty in one run, and it
was mine. `read-buffer` passed `*buffer-name-history*` — a **parameter** —
where `completing-read` wants a **history record**. A history here is a
`<history>` record (that is what a prompt adds to), and a parameter is only
*read* at the moment the answer is added — so the prompt drew perfectly,
the completion worked, and **RET** raised:

    Switch to buffer (default *scratch*): *scratch*
    Wrong type argument: #<<parameter> 7f499d9d29a0 proc: #<procedure ...>

and the minibuffer never left. `C-x b fresh RET` answered `[No match]` for
the same reason, seen from the other side.

The name now lives beside `minibuffer-history` in `minibuffer.sld` — the
same `DEFSYM`/`Fset` pair in the same C file, and the same reason
`minibuffer-history` is there. **The generalisable bit**: a value crossing
between two libraries has to have the shape the *receiving* library wants,
not the shape the library that declares it happens to use. This is the
third time a coding-system-shaped value crossed a seam in this tree and the
first time it was a parameter.

## The other departure: the confirm rule had nothing to read

`minibuffer-complete-and-exit` was a dispatch on the bitset of one
completion. Emacs 31's is a **chain of conditions tried before anything is
completed**, and the difference is what a user sees:

  * an *empty* answer exits at once (`(= beg end)`, "Allow user to specify
    null string") and the answer is the default — ours showed the
    candidates instead;
  * a valid completion exits (with the case fixed up when completion
    ignores it);
  * an answer that is **not** valid still exits when confirmation was
    asked for — for `confirm-after-completion`, unless the command just
    before the RET was a TAB. Ours refused, so `C-x b fresh RET` could not
    make a buffer;
  * and only then is anything completed.

That rule needs `minibuffer-completion-confirm` to hold the **symbol**
(`nil`, `confirm`, `confirm-after-completion`, or a predicate), and this
tree held `#t`/`#f` — a boolean cannot tell `confirm` from
`confirm-after-completion`, which is the whole of the rule. `completing-read`
now binds it with Emacs's own line (`(unless (eq require-match t)
require-match)`, `minibuffer.el:5243`), `minibuffer-confirm-exit-commands`
exists (`(list minibuffer-complete minibuffer-complete-word)` — a command
is its procedure here, and `completion-at-point` is not ported), and
`completion--do-completion` grew Emacs's `expect-exact` so that RET does
not say "Sole completion" or "Complete, but not unique" — which is what the
first version of this printed on a perfectly ordinary RET.

**`ding` is not ported**, so the predicate-confirm branch says "No match"
without a bell. Named rather than papered over.

## Verified

Every expectation is Emacs 31.1's, measured in an `emacs -nw` pty on the
same keys, and the four cases agree:

| keys | Emacs | here |
|---|---|---|
| `C-x b cxb RET` | buffer `cxb` (the name is taken as typed) | same |
| `C-x b fresh RET` | buffer `fresh` made | same |
| `C-x b RET` (empty) | the default, `*scratch*` | same |
| `C-x b cxb- TAB RET` | `[Confirm]`, and the second RET exits | same |

- `ncurses-editor-tests.scm` +9 (268): the strip-internal rule including the
  all-internal branch, `internal-complete-buffer-except`'s STRICT nil (the
  current buffer is not offered but its name is accepted), the four cases of
  the exit chain, `minibuffer-confirm-exit-commands`, and one line that is
  the regression test for the parameter — `(history? buffer-name-history)`.
- `tools/pty-check.py` gained **`switch-buffer`** (64 checks): the prompt, a
  name that exists, a name that does not, and TAB-then-RET asking to
  confirm. Verified failing with the bug put back — the failure message
  quotes the very error Chris pasted.
- All 35 suites pass, no new compiler warnings.

## Still open

- **`read-file-name`'s own exit path is unchanged.** It passes its
  MUSTMATCH through to `completing-read`, and `find-alternate-file`
  (`C-x C-v`) is the one caller that gives it
  `(confirm-nonexistent-file-or-buffer)` — so that command now gets the
  real `confirm-after-completion` symbol where it used to get `#t`. It
  wants a pty check of its own: `C-x C-v` a name that does not exist,
  TAB then RET, which should ask to confirm.
- `completion-at-point`/`completion-in-region` (step G of
  COMPLETION-PLAN.txt) do not exist, so `minibuffer-confirm-exit-commands`
  lists the two TABs that do.
- `ding` (`keyboard.c`), named above.
- Not carried, each because nothing here produces it: `get-scratch-buffer-create`
  (`simple.el:11547`) and its `initial-major-mode`/`initial-scratch-message`
  (`startup.el`), `set-buffer-major-mode` (`buffer.c:2271`), the three
  `switch-to-buffer-*` options (no dedicated windows here, and a window
  already keeps its own point), `window-dedicated-p` and `window-prev-buffers`.

# `~` in the prompt and the buffer list — and the regexp bug under them
# (2026-10-09)

Chris: *"in real emacs, when you C-x C-f it abbreviates your path that it
prompts you with, using the ~ ... Also the buffer list lists files below
your home directory with ~ rather than the full root path."*, and then
*"use emacs as a reference as usual"*.

## What was actually missing

`abbreviate-file-name` **was** in the tree — the dired pass brought it, and
`dired.sld` already called it for its buffer name and its
`dired-file-name-at-point`. What was missing was:

1. **The call sites Chris was looking at.** `read-file-name` never
   abbreviated the directory it puts in the minibuffer, and
   `Buffer-menu--pretty-file-name` was `(or file "")` with a comment saying
   the abbreviation was not here.
2. **Most of the function.** Our version was a `string-prefix?` until-the-
   first-match walk over `directory-abbrev-alist` with the home directory
   re-read on every call, and its own comment said the regexp form of FROM
   was "not ported". Emacs's `directory-abbrev-apply` (`files.el:87`) is a
   `string-match` per element that **applies every matching element, in
   order**, and replaces from `(match-end 0)`; and
   `directory-abbrev-make-regexp` (`:71`) is where the `\(/\|\'\)` group
   comes from — the thing that stops `/usr/foobar` being taken for the home
   directory `/usr/foo`.

All of it is ported now, including the pieces the simplification had left
out: `abbreviated-home-dir` as the **cache** (with the symbol property
`'home` recording which home it was built for, so a *changed* HOME is
ignored rather than believed — `get`/`put` are `fns.c`'s and are exported
from `intervals.sld` for it), the "if the home directory is just `/` don't
change it" guard, and `case-fold-search` bound from
`file-name-case-insensitive-p` so that `~` is substituted
case-insensitively only on a filesystem that does not distinguish case.

**New primitive**: `file-name-case-insensitive-p` (`fileio.c:2688`) with
`file_name_case_insensitive_err` beneath it. On this platform the C's answer
is a **constant** — its two probes are `pathconf (…, _PC_CASE_INSENSITIVE)`
and `pathconf (…, _PC_CASE_SENSITIVE)`, glibc defines neither macro, so it
compiles its own `#else return 0` branch — and Guile binds no `pathconf`
either. The walk up to an existing directory is written anyway, because it
is the C's and would be right the day one of the macros appears.

## The four call sites, each where Emacs has it

| Emacs | here | what it shows |
|---|---|---|
| `read-file-name-default` (`minibuffer.el:4085-4092`) | `files.sld`'s `read-file-name` | `Find file: ~/GITE/schemacs/` |
| `Buffer-menu--pretty-file-name` (`buff-menu.el:890`) | `buff-menu.sld` | `~/GITE/schemacs/README.md` in `C-x C-b`'s File column |
| `dired-mode` (`dired.el:2912`) | `dired.sld`, setting `list-buffers-directory` | a Dired buffer's own directory in that column |
| `cd-absolute` (`files.el:980-981`) | `files.sld` | `cd` in `*scratch*` is visible there too |

`list-buffers-directory` is `menu-bar.el`'s variable and **needs no
definition here**: this tree's buffer-local variables are a per-buffer
table keyed by a symbol, so `dired` and `cd` `set-buffer-local-value!` it
and `Buffer-menu--pretty-file-name` reads it — which is exactly Emacs's
`(bound-and-true-p list-buffers-directory)`, and it is the arm that gives a
fileless buffer anything to show. `read-file-name` also grew Emacs's
`(unless (file-name-absolute-p dir) (setq dir (expand-file-name dir)))`,
which the port had skipped.

Measured in a pty against Emacs 31.1: the prompt is `Find file:
~/GITE/schemacs/`, the File column reads `~/GITE/schemacs/README.md` for a
buffer under the home directory and `/tmp/notinhome.txt` unchanged for one
outside it, and a Dired buffer shows `~/GITE/schemacs/`.

## The bug underneath: every case-sensitive regexp was a *basic* one

`abbreviate-file-name` binds `case-fold-search` to
`file-name-case-insensitive-p`, which is nil here — and its own pattern is
`\(/\|\'\)`. It matched nothing, and that is how this was found:

    (parameterize ((*case-fold-search* #f)) (string-match "a\\|b" "b"))   ; #f
    (let ((case-fold-search nil))              (string-match "a\\|b" "b")) ; 0 in Emacs

`%compile-emacs-regexp' called

    (make-regexp (%translate-emacs-regexp pattern) (if icase? regexp/icase 0) regexp/newline)

and **a flag list containing a 0 makes Guile compile a POSIX *basic*
regular expression**. Measured:

| call | `"a\|b"` against `"a"` |
|---|---|
| `(make-regexp "a\|b")` | matches (extended) |
| `(make-regexp "a\|b" 0)` | **no match** (basic — `\|` is literal) |
| `(make-regexp "a\|b" 4)` | matches |
| `(make-regexp "a\|b" 0 4)` | **no match** |

So with `case-fold-search` nil the ERE our translator produces — `(`, `)`,
`|`, `+`, `?`, `{` — was read literally: `a+` matched only a literal "a+",
`\(ab\)+` only "(ab)+". It went unnoticed because `case-fold-search`'
default is `t` (as in Emacs), so only a *case-sensitive* search reached it,
and no test did one with a pattern that says so. The flags are now one
integer (`(logior (if icase? regexp/icase 0) regexp/newline)`), and
`search-tests.scm` has six cases with the folding off — `a\|b`, `a+`,
`\(ab\)+`, `ab\{2\}`, a case that must *not* match, and one with folding on
— every expectation Emacs 31.1's.

This is the second bug of its shape in this tree: the first was
`(or ring (error ...))` where `'()` is true in Scheme. **A port can be
wrong in the one branch its tests never take**, and here the branch was
"case folding is off" — a whole mode of the editor, reached by
`isearch-toggle-case-fold` and by any buffer whose `case-fold-search` is
nil.

## Departure left standing

**`default-directory` itself is not abbreviated at startup.** Emacs's
`normal-top-level` does `(setq default-directory (abbreviate-file-name
default-directory))` (`startup.el:771`, and again after the init file at
`:782`), so `(default-directory)` reads `~/...` in Emacs. Here it is
computed from `(getcwd)` at the point of use (`buffer.sld`), and that
library is *below* `files.sld`, so it cannot call the abbreviation — there
is no stored global to abbreviate. Everything a user *sees* goes through a
call site above it and is fixed; what remains is the value the variable
itself reports, and a buffer created with no directory of its own inherits
the unabbreviated form where Emacs's would inherit the global. Closing it
means giving `buffer.sld` a settable global for the process directory and
letting startup set it, which is a small change to a variable every layer
reads — named rather than done in a pass about two prompts.

## Tests

- `search-tests.scm` 64 (was 58): the six case-folding-off cases above.
- `files-tests.scm` 27 (was 13): the nine names (home, home with its slash,
  deeper, `/usr/foobar`-shaped, a shared last-component prefix, `/etc`,
  relative, `/`), the `directory-abbrev-alist` regexp rule,
  `directory-abbrev-apply`'s replace-from-`match-end-0`, the **warm-versus-
  cold cache** case (both answers measured — `"~/chris/y"` and `"~/y"`,
  which is what the cached regexp being the *abbreviated* home means), and
  `file-name-case-insensitive-p` answering `#f`.
- `ncurses-editor-tests.scm` 269: the File column for a file under the home
  directory, one under `/tmp`, and one with `list-buffers-directory` set.
- `tools/pty-check.py` gained **`abbreviate`** (65 checks), driving the
  prompt and the File column against a file made in a temp directory
  *under* the home directory (the home directory is the one thing it cannot
  fake), removed again afterwards. Verified failing with the abbreviation
  taken out of `read-file-name`: `Find file: /home/chris/sc-.../`.
- `files-tests.scm` also has `cd` setting `list-buffers-directory`
  (`files.el:981`) - the other way a File column gets filled.

### The harness races, fixed rather than slept over

`save-y-n` failed one run in three with the file **correctly saved**
(`'Xhello\n'`) and `exited=False`: the save writes its file, the editor
goes quiet while the write lands, and it exits only after that - and
`drive` reaped it at the silence. That is the same "quiet is not done"
note this file carries about the per-key settles, and it is the last of
them: **a key list can now carry the condition a check is waiting for**
instead of relying on a pause.

    drive([C_x + C_c, WAIT(b"Save file"), b"y", EXITED], path, report_exit=True)

Two markers, and nothing else changed:

  * **`WAIT (TEXT)`** - drain until TEXT has been drawn, then send the
    next key. The check says what the next key is *about*: `C-x C-f` then
    `C-a` was a race because `C-a` sent before the prompt is up acts on
    the buffer, and now it waits for `b"Find file: "`.
  * **`EXITED`** - wait until the process is gone, and remember it. A
    check whose condition *is* "the editor quit" asks this rather than
    reading the silence after its last key.

Both give up after `KEY_MAX`, and **a timeout is named in the screen text
the check prints on failure** (`WAIT_TIMED_OUT`), so a check that waited
for the wrong thing no longer fails three assertions later looking like an
editor bug.

**And that marker is a trap the moment you assert on the thing you waited
for, which is the obvious thing to write.** `WAIT` puts the text it gave up
on *into the screen it returns* -

    [[harness: gave up waiting for b'modified; kill anyway?']]

- so `if b"modified; kill anyway?" in out` is **true whether or not the
prompt ever came up**, and the check passes while the editor is raising an
error underneath it. Found the hard way: a new check for `C-x k` on a
modified buffer asserted on its own `WAIT` text, passed, and was hollow.
Assert on something only the real thing produces - the two versions differ
in text that the marker does not contain (here the *choices*,
`(yes/no/save and then kill)`) - and verify by stashing the fix and
watching the check go red. A green check that has never been seen to fail
is not evidence, and one built on a `WAIT` marker cannot fail.

Seven checks were converted - `save-y-n`, `isearch-quit`,
`quit-completions`, `default-directory`, `find-file-read-only`,
`find-alternate-file` and `minibuffer` - which is every check this file has
ever named as flaky, plus two more with exactly the same shape. Measured:
**7/7, three runs in a row, with the machine held at load average 5.1 by
six busy loops** - the condition the old fixed pauses lost under (22/62
once, from the startup race alone).

The lesson this file keeps relearning, now with the mechanism to act on it:
a pause is a guess at how long the editor takes, and a guess is a race. A
check that knows what it is waiting for should say so.

## Still open

- The startup abbreviation above.
- `abbreviate-file-name`'s MS-DOS drive-letter guard is not carried (there
  is no `system-type` here, and the branch is about `C:/`).
- The handler arm is there and answers nothing, because no file-name
  handler is registered — as Emacs's does on a machine with none.

# The `~` completion bug my own `~` change let through (2026-10-09)

Chris, the same day the abbreviation landed: *"you seem to have broken file
completion with your tilde ~ changes."* He was right, and the shape of it
is worth keeping.

## The symptom

`C-x C-f` in a buffer under the home directory, then TAB:

    Find file: ~/GITE/schemacs/No such file or directory

The prompt was right - that was the feature - and completion in it was
dead, which my checking had missed: the pty check I wrote for it asserted
the *prompt text* and the *File column* and never once pressed TAB.

## The two departures, both "a primitive that does not expand where the C does"

1. **The completion table resolved the directory by hand.**
   `file-name-completion-table` had

       (realdir (cond ((string=? specdir "") (default-directory))
                      ((char=? (string-ref specdir 0) #\/) specdir)
                      (else (string-append (default-directory) specdir))))

   - a branch Emacs does not have, because **the C expands the directory
   inside `file-name-completion` and `file-name-all-completions`**
   (`directory = Fexpand_file_name (directory, Qnil);`), and makes sure it
   ends in a slash. With an absolute `specdir` the hand-rolled branch
   agreed with the C by luck; with `~/GITE/schemacs/` it produced
   `/home/chris/GITE/schemacs/~/GITE/schemacs/`, `opendir` raised, and TAB
   reported the errno. It is Emacs's own line now -
   `(realdir (or specdir default-directory))` (`minibuffer.el:3721`), then
   the expansion and the slash the C does.

2. **`file-exists-p` was the one predicate that did not expand its
   argument.** The C's shared body `check_file_access` (`fileio.c:2992`)
   opens with `Fexpand_file_name`, and so do `file-writable-p`,
   `file-directory-p` and everything else in that family — `readable-p`,
   `executable-p`, `symlink-p`, `regular-p`, `modes`, `diredc`'s
   `directory-files` and `file-attributes`, all of which already expanded
   here. Measured, before the fix:

   | call | Emacs | was | now |
   |---|---|---|---|
   | `(file-exists-p "~/GITE")` | `t` | **`#f`** | `t` |
   | `(file-directory-p "~/GITE")` | `t` | `t` | `t` |
   | `(file-exists-p "~")` | `t` | **`#f`** | `t` |

   The asymmetry inside one family is what makes this class dangerous:
   `file-directory-p` expanding and `file-exists-p` not looks like it
   works, right up to the call that uses the one that does not — here the
   table's "is what has been typed already a name?" question
   (`file-exists-p`, `minibuffer.el`'s ACTION `lambda` branch), which
   answered nil for every abbreviation. `file-writable-p` now expands once
   at the top as the C does, since its `access?` is a syscall that would
   otherwise resolve a relative name against the *process's* directory
   rather than the buffer's.

**The lesson, and it is the file's oldest one**: the change that exposed
this was itself a *correct* port. It failed because a primitive underneath
it did not do what the C does, and no test passed a `~` to a file
predicate before. When a port is built on top of another, the cheaper port
is the one that has never been asked the question.

## Named, not done

`completion-file-name-table`'s **user-name** branch
(`minibuffer.el:3695`, completing `~ro` to `~root/`) is not ported: it
needs `system-users`. A `~user/x` still resolves, because
`expand-file-name`'s `~USER` rule is the C's and is ported — what is
missing is completing the user's *name*.

## Tests, and the gap in the old one

- `fileio-tests.scm` 60 (was 55): `file-exists-p` on `~`, `~/`, `~/.` and
  a missing `~/...` name, plus the whole family on `~` in one row
  (`(t t t nil nil nil t)`), every answer Emacs 31.1's.
- `files-tests.scm` 29: the completion table with `~` in the directory,
  through `all-completions` and through `test-completion`.
- **`tools/pty-check.py`'s `abbreviate` check now presses TAB** in the
  abbreviated prompt and asserts the name completes — the assertion whose
  absence is the whole reason this shipped. Verified failing with the old
  `realdir` put back: the message is the symptom, "TAB in a prompt holding
  '~/sc-.../' did not complete a name in it: ... `No such file or
  directory`".

# The harness onto `se`, and the platform reorganisation (2026-10-09)

Two jobs Chris asked for in one breath: *"fix the test harness, then do a
reorganisation. The new hierarchy is `schemacs/ui/gtk` and
`schemacs/ui/ncurses` … Then I want you to move every file / module under
schemacs that is either gtk or ncurses specific under one of those
directories. Then … only one thing importing either ui/gtk/gtk.scm or
ui/ncurses/ncurses.scm, and that would be main."*

## The harness now drives `se`, which found three real bugs

`tools/pty-check.py` used to start `main-ncurses.scm` - a *second launcher*
that duplicated `se` + `schemacs/main.scm` (env var, back door, port-file
cleanup) and did less (no `-w`, `--chdir`, `-q`, usage). Chris deleted it,
so `drive()` now spawns `[REPO/se] + args` with the same environment. That
change alone turned the battery red, and every failure was a real bug that
the second launcher had been hiding:

1. **`schemacs/main.scm`'s `SCHEMACS_REPL` branch had `port` out of scope.**
   It read `(let ((port (string->number env))) (when port (start-repl-in!
   port))) port` - the answer *outside* the `let` that binds it. So the
   env-var way to open the door answered **`Unbound variable: port`** and
   the door never opened under `se`. `main-ncurses.scm` had its own copy of
   that code, which worked, so nothing drove this path.
2. **The launcher's error reporter was itself broken, and hid (1).** It
   called `(format (current-error-port) …)` by *name*, and this file is
   `load`ed into `(guile-user)` - where the user's init file imports
   editor libraries, one of which exports `format` (`(schemacs editfns)`, Emacs's, string-first). The reporter was then handed a port
   as its format string, and all the terminal showed was `Wrong type
   argument … #<output: file /dev/pts/8>`. Now captured once as
   `%guile-format` at the top of the file. **An init file can shadow the
   launcher's own bindings**; anything this file calls by name is at risk.
3. **`not-modified` asserted an exit without waiting for one** - the eighth
   check of that shape, converted to `EXITED` like the other seven.

## The layout

```
schemacs/ui/gtk/gtk-main.sld          (schemacs ui gtk gtk-main)
schemacs/ui/gtk/pgtk.sld              (schemacs ui gtk pgtk)
schemacs/ui/gtk/pgtk-names.scm        (schemacs ui gtk pgtk-names)
test/ui/gtk/pgtk-test.scm
schemacs/ui/ncurses/ncurses-main.sld  (schemacs ui ncurses ncurses-main)
schemacs/ui/ncurses/term.sld          (schemacs ui ncurses term)
schemacs/ui/ncurses/xterm.sld         (schemacs ui ncurses xterm)
```

**A library name is its path, and the path cannot repeat the last
component.** Chris asked for `ui/gtk/gtk.sld`; Guile resolves `(a b)` to
`a/b.sld` and *does not* try `a/b/b.sld` - measured in a scratch tree,
`no code for module (x y)` - so the entry is `gtk-main.sld`/`ncurses-main.sld`
(Chris's own suggestion) under the directory it belongs to.

`loadup.sld`'s excluded list is down to **itself**. The toolkit pair used to
be named there so that a terminal session would not drag guile-gi in; now
those libraries are *outside* `schemacs/editor/`, and `loadup-tests.scm`
walks that directory - so the rule is structural instead of a note that can
be forgotten. That also closed the leak found in the previous pass
(`(schemacs editor xterm)` bound guile-ncurses and *was* in the
session's list, so a GTK back door loaded ncurses).

**Shared stays in `editor/`** - `dispnew.sld`, `select.sld`, `frame.sld`,
`xfaces.sld`, `faces.sld`, and `tty-colors.sld`, which the shared face
layer imports (`xfaces.sld`'s `tty-color-translate`, as Emacs's
`xfaces.el` uses `tty-colors.el`). Moving `tty-colors` on its name's
flavour would have had the editor core importing out of `ui/`, which is
what the whole split is for.

## Left to do: the tests still reach into `ui/`

`tools/check-missing-imports.py`-style greps now show four files outside
`ui/` importing it (plus `main.scm`, which is allowed):

| file | what it imports | why |
|---|---|---|
| `apps/ncurses-editor-tests.scm` | `(schemacs ui ncurses term)` `<tty-display>` | needs *a* display; its own comment says "a terminal object with nothing behind it" |
| `editor/faces-tests.scm` | same, `term:` prefix | subclasses it as `<test-display>` |
| `editor/select-tests.scm` | `<tty-display>` **and** xterm's OSC 52 helpers | the first is a display object, the second is the terminal's behaviour |
| `editor/mouse-tests.scm` | `(schemacs ui gtk pgtk)` `<pgtk-display>` | needs `line-height` in pixels |

The first three are one mistake - a shared test borrowing a concrete front
end to get a display object - and the fix is a **stub display** (the
`dispnew` generics with no default: `write-glyphs!`, `realize-face`,
`screen-size`, `column-width`, `line-height`, `display-color-cells`,
`key-event->key`, …) with the geometry as its fields. The ncurses *key
table* and xterm's OSC 52 selection cannot be stubbed (they are the
terminal's facts), so those assertions belong in `ui/ncurses/`.

## The purge, and the library that was deleted while still imported

Chris purged the tree on the strength of the audit in the previous message,
and one file it called dead was not: **`schemacs/pretty.sld`**, which
`keymap.sld` and `vbal.sld` import for real. The editor stopped starting -
`no code for module (schemacs pretty)` - and it was restored.

What `pretty.sld` *does*, since he asked: it is a debug pretty-printer -
`print`/`pretty` plus the layout helpers (`bracketed`, `newline-indent`,
`indent-by`, `join-by`, `repeat`, `line-break`) and `qstr`. Its only
customers are three structure printers, and **nothing calls any of them**:
`keymap-print`, `keymap-layer-print`, `keymap-index-print`,
`char-table-print` (each self-recursive and exported), `print-vbal` /
`print-vbal-with`, and `bin-hash-table-print`. They are REPL debugging aids
- `(keymap-print m)` at the back door - on no path the editor runs. So the
complete deletion is `pretty.sld` **plus** those seven definitions and their
imports in the three live libraries; not the library alone.

**Two method lessons, both mine:**

- **"Reachable from a test" is not "used by the editor"** and the first
  audit conflated them, which is what made the whole `elisp-eval/` layer
  look live: its only route in was `elisp-eval/print-tests.scm`, a file in
  the suite list. Ask the two questions separately - the editor's roots
  (`se`, `schemacs/main.scm`, the pty harness) versus the tests'.
- **Before deleting, grep the tree for the library's name.** The audit's
  importer list for `pretty.sld` named `elisp-load.sld` alone; the grep
  found four importers including `keymap.sld` and `vbal.sld`. *Why* the
  computed list was wrong is not established - re-running the same
  stripping on the same file afterwards finds the import - so the lesson is
  not "the graph is buggy" but **do not delete on one tool's say-so**:
  `grep -rl "$(name)" --include='*.sld' --include='*.scm' .` over the whole
  tree, for *every* file about to go, and read the hits.

# The imports facility, and `define-custom` (2026-10-14)

Chris, after the session that ended with "you can start working on the
imports scheme":

> the editor should try and load `$XDG_CONFIG_HOME/imports.scm`, which
> should be just a list of imports, and that should load `(schemacs editor
> imports)` which includes all the editors built in imports. ... it loads
> that as the environment for M-: and REPL and also for the init.scm
> environment ... The name wouldn't be loadup, but `(schemacs editor
> imports)`. And to be clear, the editor itself shouldn't use that
> internally as a cheat, it should only use that for those 3 scenarios.

and later, on what the user gets:

> the user has full control over what is imported into his default
> environment ... I wouldn't want some thing where he has to write a file
> importing a bunch of things and re-exporting it again.

## The user environment

Three places evaluate code the editor did not write, and so three places
with no `import` to write: **`M-:`**, the **REPL back door**, and the
user's **`init.scm`**. GNU Emacs has one obarray, so all three reach
`find-file` with no `require`; this tree's names live one library per
Emacs file, so they need somewhere to look.

- **`schemacs/imports.scm`** - `(schemacs imports)`, which
  imports all 62 `(schemacs editor ...)` libraries and re-exports their
  1712 names. **Generated**: `tools/gen-imports.scm` (with `--check`),
  because a hand-written list of that size is wrong within a week. Guile's
  `define-library` has **no `re-export`** (measured), which is why the
  export list is written out rather than named.
- **`loadup.scm`** - `imports-path` and **`open-user-environment!`**:
  imports the whole editor into a module, or, when the user has one,
  evaluates `$XDG_CONFIG_HOME/imports.scm` - or
  `$XDG_CONFIG_HOME/schemacs/imports.scm`, beside `init.scm` - *as* the
  environment. **A file replaces the default rather than adding to it**,
  which is the "full control" reading: a file that does not name the
  editor gets an environment without it (and the pty check asserts
  exactly that).
- The three consumers are one call each: `start-repl!`, the boot in
  `startup.scm` (Emacs's `normal-top-level`), and
  `%eval-expression-environment`.

**What it fixed.** `M-:` evaluated in `(current-module)`, and the module
current while a *command's* interactive spec is being evaluated is the
command's defining library - so the same expression went to a different
module depending on whether it was typed at a prompt or read by the back
door, and in a library, which has no `import` to offer. All three now read
one module.

**The editor's own libraries do not use it**, and `loadup-tests.scm`
keeps the list honest: it walks `schemacs/editor/*.scm` and fails on a
library that is neither in `editor-libraries` nor excluded on purpose.
`(schemacs imports)` is excluded, and must be - it imports every
library, so a list naming it would be a cycle.

Tests: `loadup-tests.scm` (16) and `pty-check.py`'s **`imports`**, which
drives all three consumers in one run and is verified to fail when
`imports.scm` is ignored (reverted by making `open-user-environment!`
read the default).

## The clash census, and the four bugs under it

`(schemacs imports)` imports sixty libraries into one module, which
is the first thing that ever asked *"do two libraries export the same
name?"*. The generator resolves the harmless case (one binding offered
twice - `simple` re-exporting what `cmds` owns, `files` re-exporting
`buffer`'s `find-buffer-visiting`) by `except`-ing it from all but the
first library, and `loadup-tests.scm` **checks that every excepted name is
one binding** - because the same trick would silently pick a winner for two
libraries that each define their own. Four were:

1. **`casefiddle` still exported `upcase-region`/`downcase-region`** after
   the commands moved to `simple.scm`. An export of a name a library does
   not have is an **unbound variable** in every module that imports it -
   `(import (schemacs casefiddle))` was handing out two of them, and
   had been since the move.
2. **`*minor-mode-alist*` was defined twice**, in `subr.scm` and in
   `xdisp.scm`, so the mode line read one alist and `add-minor-mode` wrote
   the other: a minor mode registered the Emacs way never reached the mode
   line. `xdisp` imports it from `subr` now, which is where
   `add-minor-mode` lives.
3. **`kill-buffer`**: `buffer.c`'s one function is two here - the
   *mechanism* (which asks `kill-buffer-query-functions` and leaves the
   buffer list) and the *command* (which needs the minibuffer's "modified;
   kill anyway?"), because commands that prompt cannot live below the
   minibuffer. The command kept Emacs's name; **the mechanism is
   `%kill-buffer` now** (`window.scm`, `files.scm` and `buff-menu.scm`
   updated). And the Buffer Menu's `x` now calls the **command**, as
   `Buffer-menu-execute` does (`buff-menu.el:619`) - so it asks about a
   modified buffer, which it did not.
4. **`mouse-position`**: `frame.c`'s Lisp function and the display *hole*
   the C calls through (`terminal->mouse_position_hook`) shared a name,
   with `frame.scm` importing the generic under an alias to get by. The
   seam is **`display-mouse-position`** now - the tree's spelling for a
   display method - and the alias is gone.

## `define-custom`

`schemacs/custom.scm`, mirroring **`custom.el`** (Emacs 31 keeps
`defcustom` there, not in `cus-edit.el`):

```scheme
(define-custom *scroll-step* 0
  "Number of lines to scroll when point goes off screen."
  :type 'integer
  :group 'scrolling)
```

`custom-declare-variable` with the C's whole keyword walk, the
`custom-add-*` family, `custom-handle-keyword`, the four live initializers,
`custom-variable-p`, `custom--standard-value`, the hook and
`custom-dont-initialize`. **Not ported**, each named in the file: the
Customize buffers and widgets, themes, `setopt`/`custom-set-variables`
(nothing writes `saved-value` yet - the initializers read it, so the day
something does, they honour it), `custom-initialize-delay` and
`-after-file-load` (dump-time; no dump here), `defface`/`defgroup`.

Every expectation in `custom-tests.scm` (18) was measured on Emacs 31.1
first. The one worth knowing: **the default initializer calls the `:set`
function when the declaration runs**, so an option whose `:set` doubles
reads 10 and not 5.

**What `define-custom` defines is a parameter** - `(define *name*
(make-parameter standard))`, read as `(*name*)` - because Emacs's
`defcustom` makes a *special* variable and ported Elisp `let`-binds
options (`(let ((fill-column 40)) ...)`). It was a plain variable between
2026-10-14 and 2026-11-07, while the plan was to purge parameters; that
plan is dead, and the convention above makes a dynamically bound variable
a parameter whose name carries asterisks.

**Departures, all named in the file**:

- **`custom-declare-variable` is handed the variable's reader and writer.**
  Emacs reaches a variable through `symbol-value`/`set`, and a Scheme
  binding has no such reflection, so the macro passes the two closures
  down. The variable itself is a parameter.
- the keyword is written `:type`, as Elisp writes it, and read as *data* by
  the macro - Scheme has no self-evaluating `:type`, and this is how
  `define-minor-mode` already spells `:lighter` and `:variable`.
- **STANDARD is kept as a thunk** where Emacs keeps the form and `eval`s
  it; same contract (callable again for the standard value), no `eval`,
  and the expression keeps its lexical scope.
- **the variable is bound before `custom-declare-variable` runs**, because
  a parameter must be made with a value; the initializer then sets it to
  what it already holds. Observably Emacs's.

## `get` and `put` were wrong, and had never had a caller

`intervals.scm`'s `get`/`put` - `fns.c`'s symbol properties - were
`symbol-property`/`set-symbol-property!`, Guile's object properties. Two
things wrong with that, and the second is the one that bites:

1. Guile's `symbol-property` takes a property **object** made by
   `make-object-property`, not a name, so `(get 'foo 'standard-value)` -
   Emacs's spelling - raised.
2. **The values are held weakly.** Measured:

       (put 'a 'x (list 1))
       (gc)                      ; -> (1), still there
       (put 'b 'y (list 2))
       (gc) (gc)                 ; -> #f  and  #f

   This is what made a `custom-group` vanish between two reads in
   `custom-tests.scm`, and it is invisible in any test that does not
   allocate in between - which is why "the first caller" is where it
   showed up.

They are a table keyed by `(symbol . property)` now: any symbol may be a
property name and the value lives as long as the symbol, as Emacs's plist
does. `make-object-property` is still used where it is the right tool -
`string-intervals-property`, where the owner is a string and the weakness
is the point.

**The lesson, again**: `get`/`put` had no caller in the tree, so both
faults sat there. A primitive with no caller is not "probably fine"; it is
unmeasured.

## Two method notes from this pass

- **`'#,(x)` is not `(quote <datum>)`.** Splicing a keyword into a macro's
  output as a *datum* is "raw symbol in macro output"; keeping the keyword
  as an *identifier syntax* and unsyntaxing it inside a `quote` form -
  `#`(list (quote #,k) ...)` - is the ordinary `(quote :type)` and emits
  the symbol. The first version did it the other way and cost a round.
- **The clause walk lives in one procedure** (`custom--apply-clause!`),
  not in a `cond` nested in a walk nested in a `let` nested in a
  procedure. The arms are the C's arms; the nesting is where the
  parenthesis errors came from, and flattening it removed them.

## Parameters are a convention, not a requirement (2026-10-14)

Worth writing down because it took a long argument to get straight, and
because it is a standing decision.

This tree defines its dynamic variables as **parameters** (SRFI 39):
`(define *current-buffer* (make-parameter #f))`, read as
`(*current-buffer*)`. 287 of its definitions are parameters and there are
326 `parameterize` forms. The first version of `define-custom` followed
that, and Chris rejected it:

> having custom variables as parameters is a worse departure than the
> supposed thing it tries to fix

He is right, and the arguments I first offered for it were all bad:

- **"you cannot rebind a plain variable for a scope"** - you can.
  `save-current-buffer` (`buffer.scm:498`), *the* dynamic-binding idiom in
  this tree, does its save and restore **by hand** and never calls
  `parameterize`:

      (define (save-current-buffer thunk)
        (let ((saved (*current-buffer*)))
          (dynamic-wind (lambda () #f) thunk
                        (lambda () (*current-buffer* saved)))))

  A parameter is being used there as a settable box, and a plain variable
  would do the same.
- **"the one-line spelling"** - a `syntax-rules` over a plain variable
  gives the same one line. Nothing about it needs a parameter.
- **"thread-locality"** - a parameter's value is per-thread, which is not a
  feature here: it *hides* state, and this tree has already been bitten by
  exactly that (the `*repl-wake*` fluid a thread created earlier could not
  see, so it had to become a plain variable).
- **"continuation-correct restoration"** - a real difference from
  `dynamic-wind` on re-entry, and irrelevant here: the editor's
  continuations are one-shot escapes.

**So a variable being a parameter is a style choice this tree made, and it
is paid for at every use site** - `(foo)` rather than `foo`. Custom
variables must not pay it: a user option is read by naming it, and that is
the whole shape of `defcustom`.

Chris, on where this leaves the rest:

> I think maybe the long term goal might be to thread variables through the
> call hierarchy, but having custom variables as parameters is a worse
> departure than the supposed thing it tries to fix.

So: the editor's internal state (`*current-buffer*`, `*case-fold-search*`,
...) stays as it is for now; threading it through call signatures is a
possible direction and a separate decision, and it is *not* what the
parameters are doing - they are dynamic binding, not argument passing.

**Superseded 2026-11-07.** The two paragraphs above record a decision that
has been reversed. Custom variables are parameters after all: `defcustom`
makes a *special* variable, ported Elisp `let`-binds options, and the
convention formalised at the top of this file makes a dynamically bound
variable a parameter whose name carries asterisks. The argument for a
plain variable - "a user option is read by naming it" - was an argument
for spelling, and it bought a variable that a ported `let` would shadow
silently instead of binding.

# The menu bar on Gtk - the widget tree, and a click back to a key
# (2026-11-09)

The Lisp stack landed in `b796e33` (keymaps -> `map-keymap` ->
`define-key-after`/`keymap-canonicalize` -> `parse_menu_item`/
`menu_bar_items` -> `menu.c`'s `menu_items` -> `digest_single_submenu`).
This pass is the other end: `gtkutil.c`'s widget builders, and
`menu.c`'s `find_and_call_menu_selection`, so that clicking an item runs
the command the item stands for.

## What is where

| Emacs | here |
|---|---|
| `set_frame_menubar` (deep branch, `xmenu.c:970`) | `pgtk-set-frame-menubar` / `pgtk-install-menubar!` |
| `create_menus` (`gtkutil.c:3405`) | `pgtk-create-menus` |
| `make_menu_item` (`:3256`) | `pgtk-make-menu-item` |
| `make_widget_for_menu_item` (`:3222`) | `pgtk-widget-for-menu-item` |
| `xg_create_one_menuitem` (`:3317`) | `pgtk-create-one-menuitem` |
| `find_and_call_menu_selection` (`menu.c:876`) | `find-and-call-menu-selection` (`menu.scm`) |
| `menubar_selection_callback` (`xmenu.c:794`) | `pgtk-menu-selection!` |
| `menu_separator_name_p` (`keyboard.c:8608`) | `menu-separator-name?` (`keyboard.scm`) |
| `xg_create_frame_widgets`' vbox (`gtkutil.c:1800`) | `pgtk-open-window`'s `vbox`: bar above the drawing area |

The window is now `GtkWindow > GtkBox > {GtkMenuBar, GtkDrawingArea}` -
`FRAME_GTK_OUTER_WIDGET` holding the menu bar and the edit widget. The
grid is the *area's* allocation (`size-allocate` moved there), and the
window is grown by the bar's height so a menu bar costs no text rows,
which is what `adjust_frame_size (f, -1, -1, 2, false, Qmenu_bar_lines)`
does (`pgtk-grow-by-menubar!`).

A click emits the item's key sequence - `menu-bar`, then each submenu
prefix, then the item's key - one event at a time through
`pgtk-enqueue!`, so the command loop's modal lookup walks it exactly as it
walks a fast-typed chord. Verified live under broadway: a menu item bound
to a `define-command` ran when `menu-item:activate` was called on the
widget.

## guile-gi owns widgets through the proxy - measured, twice

A guile-gi proxy owns its GObject with a **toggle reference**, so a proxy
that is collected *destroys the widget*, even though Gtk's container
holds it. Measured under broadway, with `gc` forced: a bar with all its
items' proxies in a Scheme variable built and activated correctly; the
same bar with the *vbox* unheld died at the first collection with
`instance with invalid (NULL) class pointer` and `g_signal_handlers_destroy`
CRITICALs. Every menu widget's proxy is therefore held for the display's
life (`pgtk-hold-widget!`, the `menubar-held` slot) - the same rule
`pgtk-window`/`pgtk-area` already follow and `*pgtk-destroyed-displays*`
documents. Emacs has no proxy and so no such rule.

**Departure, named**: a rebuild keeps the old widgets' proxies too, so a
menu whose contents change often (a Buffers menu) grows the hold list.
Freeing them needs "unparent the whole subtree, then drop the proxies",
which is not the same order as the crash-free case above and has not been
worked out.

## Three departures in the machinery, all resolved against the C

1. **`access_keymap` does `get_keyelt`'s coercions** (`keymap.c:678`):
   `(STRING . DEFN)` -> DEFN, and `(menu-item NAME DEF ...)` -> DEF. Both
   are *menu spellings* of a keymap binding, and without them
   `[menu-bar file save-buffer]` has no binding and a clicked item's key
   sequence stops at the first symbol. This is what `menu-bar.el`'s
   `(define-key global-map [menu-bar file] (cons "File" ...))` needs.
2. **`parse_single_submenu` no longer initializes `menu_items`** - its C
   caller does, once for the whole bar, and initializing per submenu made
   every bar item's panes discard the last. `menu-tests.scm` wraps its
   calls the way `set_frame_menubar` does.
3. **`dispatch-action` accepts a command *symbol*.** Elisp writes
   `(menu-item "Save" save-buffer)`; this tree's keymaps hold procedures.
   `command-record-named` is the obarray lookup (`*command-table*` is
   keyed by the command's name *string*, not a symbol).

Found on the way: `lookup-keymaps` listed `*default-keymap*` twice,
because the front ends bound `*current-keymap*` to it explicitly. Harmless
for a key and visible in the bar (every item contributed twice); the front
ends now bind `#f`, which the parameter already documents as "use
global-map".

## Not carried yet

- **`menu-bar.el` itself** - the standard menus (File/Edit/Options/
  Buffers/Tools/Help), `menu-bar-update-hook`, `activate-menubar-hook`,
  `menu-bar-mode` (which needs frame parameters: `menu-bar-lines`), and
  `easy-menu-define`. Until then the bar shows whatever user code defines
  under `[menu-bar]`, and is hidden when there is nothing.
- `set_frame_menubar`'s *shallow* branch (only item names recomputed),
  and the `menu-bar-lines` frame parameter.
- The `:filter`-driven `get_keyelt` re-evaluation (`autoload` argument).

## The empty menu bar cost a keystroke (2026-11-09)

Chris, after the menu bar landed: *"performance seems to have gone to hell.
Just moving the cursor around is dog slow."* Two causes, both measured.

**1. An empty bar was rebuilt on every redisplay - 6.6 ms of it.** The C
rebuilds an empty bar (`i != 0` in its guard) because its rebuild is a few
Lisp calls; here `pgtk-install-menubar!` ran `container:get-children` and
`widget:hide` every time, two guile-gi crossings, on every keystroke, for
a bar with nothing in it. `pgtk-set-frame-menubar` now takes an empty bar
down **once** (`menubar-hidden?`) and returns. Measured on a compiled
editor: `pgtk-set-frame-menubar` **6.6 ms -> 0.009 ms** per redisplay.

**2. The editor was running *interpreted*.** `bin/se` passes
`--no-auto-compile`, so a library with no `.go` in
`~/.cache/guile/ccache` is *loaded as source and evaluated*, not compiled.
Measured on the same editor and buffer: `render!` **79 ms** with a cold
cache, **22 ms** warm. Deleting this tree's cache while working - which
every measurement run does - leaves any editor started afterwards
interpreted, and an interpreted redisplay is the "dog slow" that started
this. **Compile the tree before saying a performance number means
anything**, and remember that a running editor keeps the code it started
with.

The break-down, once both are fixed (compiled, 80x24, themed): `render!`
6-7 ms, of which `render-window!` is 1.2 ms and `flush-display!` 3.3 ms
(two guile-gi crossings). The rest is the per-keystroke full redraw this
file already names as the remaining gap - `render!` clears the surface and
redraws every row instead of an incremental update.

## `message` moved point in `*Messages*` (2026-11-09)

Chris: *"`(message "")` moves point to the end of the messages buffer.
Emacs doesn't move point. If point moves it is hard to copy out of
messages because setting mark to copy outputs a message 'mark set' which
moves point."* Both halves are one bug: our `message-dolog` ended with a
flat `(goto-char (point-max))`.

`message_dolog` (`xdisp.c:12381`) reads `PT == Z` *before* it moves to the
end, and restores afterwards:

```c
      if (PT == Z) point_at_end = 1;
      ...
      TEMP_SET_PT_BOTH (Z, Z_BYTE);            /* insert at the end */
      ...
      if (point_at_end) TEMP_SET_PT_BOTH (Z, Z_BYTE);
      else TEMP_SET_PT_BOTH (marker_position (oldpoint), ...);
```

So a log buffer left at its end follows new messages - which is what
scrolling with the log looks like - and one whose point is anywhere else
keeps it. The old point is kept as a **marker**, so trimming the oldest
lines for `message-log-max` moves it back with the text it was on.

Ported as it stands: `point-at-end?` from `(= (point) (point-max))`
before the move, `(point-marker)` for the old point, and the restore at
the very end, after the duplicate folding and the trim.
`ncurses-editor-tests.scm` has the three cases (point kept, point at the
end follows, both messages logged), measured against Emacs 31.1, and the
first one fails with the old code (`actual 265`, the end of the buffer).

## `[Confirm]` could never fire from a TAB (2026-11-09)

Found by the pty battery, and *not* this pass's doing: the `switch-buffer`
check failed on `HEAD` as well (checked by stashing and running it on the
clean tree). `C-x b SWI TAB RET` showed `[No match]` from the TAB and
then made a buffer named `SWI` - the typo `confirm-after-completion`
exists to catch, exited straight through.

`completion--in-region-1` (`minibuffer.el:1745`) sets **`this-command` to
the *symbol* `completion-at-point`**, so a RET straight after a TAB sees
`last-command` = that symbol. Emacs's `minibuffer-confirm-exit-commands`
is a list of symbols and contains it. Ours had been translated to the two
*procedures* that are bound to TAB ("a command is its procedure here"),
and `completion-at-point` was left out because it is not ported as a
command - so `(memq last-command ...)` was false for the symbol, and the
confirm branch was never taken.

The list now holds `(completion-at-point minibuffer-complete
minibuffer-complete-word)` - Emacs's list, with the two that are bound
given as the procedures they are bound as. The pty check passes again.

# `menu-bar.el`, as far as the tree can back it (2026-11-09)

`schemacs/menu-bar.scm` is new and mirrors `lisp/menu-bar.el`.
It is not the whole file: most of that file's items name commands this
editor does not have, and an item that names one is a menu entry that
signals when clicked. What is here is the machinery and the two menus
the tree can back, with every omission listed in the header against
the thing it waits for - which is the accounting this file asks for,
rather than a "faithful subset" that stops the next person asking.

## What landed

- **The bar's own keymap** (`menu-bar.el:40`): `[menu-bar]` in
  `global-map`, made only if nothing has made it ("Don't clobber an
  existing menu-bar keymap"), and **`menu-bar-final-items` set to
  `(help-menu)`** (`:46`).
- **`menu-bar-separator`**, and the lesson it carries: a separator is
  `'(menu-item "--")`, *not* a bare `"--"`. `parse_menu_item` refuses a
  binding that is not a cons, so a string in a menu is skipped
  entirely - which is why a first attempt at these menus showed one
  fewer item than it defined.
- **`kill-this-buffer`**, with the C's guard ported as far as the event
  model goes: the item's key is the symbol `kill-buffer`, and a menu
  selection leaves that as `last-command-event`, so a call from the
  menu is told from a call typed at M-x by exactly Emacs's test.
- **The File menu**, less Print, the tabs, Undelete Frame, the monitor
  and display-server frames, Recover Session and the project entries;
  **the Edit menu**, less Fill, Bookmarks, Go To and Search, with its
  Incremental Search and Replace sub-menus, themselves less the regexp
  and symbol searches. Same keys, same order, same labels and `:help`
  strings as the C.
- **`activate-menubar-hook` and `menu-bar-update-hook`** in `xdisp.scm`
  (they are `xdisp.c`'s DEFVARs, not `menu-bar.el`'s), and
  `pgtk-set-frame-menubar` runs them before it reads the items, as
  `set_frame_menubar` does (`xmenu.c:994-1000`).

## Two things the tree spells differently, both on purpose

- **`t` in a menu item is `#t`.** `:enable t` left `t` as a *symbol*,
  `menu-item-eval-property` tried to evaluate it, failed, and answered
  nil - so "Revert Buffer" and "Remove Other Windows" were greyed out.
  A literal in a menu item is Scheme; `t` is not a value here.
- **`:enable` reads functions, not variables.** `mark-active` is
  `(mark-active)`, `buffer-read-only` is `(buffer-read-only? (current-
  buffer))`. They are evaluated when the bar is built, in the editor's
  own environment, which is the same environment the item's command is
  found in.

## Verified live, on a gtk editor under broadway

The bar shows `File` and `Edit`; File reads *Visit New File... Open
File... Open Directory... Insert File... Close / Save Save As... Revert
Buffer / New Window Below New Window on Right Remove Other Windows /
New Frame Delete Frame / Quit*; Edit reads *Undo Redo Cut Copy Paste
Select All Incremental Search Replace Execute Command*, with Replace
opening on its two entries.

`:enable` is live in both directions: **Save** is greyed on an unmodified
buffer, **Cut** and **Copy** are greyed with no mark, and activating
**Select All** then re-reading the widgets shows them enabled - the
built `menu_items` array carries the *evaluated* enable slots, so a
change in them is what makes the bar rebuild.

Activating **Cut** from the menu emptied the buffer and put the text on
the kill ring; **Select All** on `"abc"` left point at 1 and the mark at
4, which is Emacs 31.1's own answer measured on the same buffer. (A
first run looked wrong - mark 1 - because the test buffer was empty:
`mark-whole-buffer` on an empty buffer *is* point 1, mark 1.)

## Tests

`menu-bar-menus-tests.scm` is a suite of its own, in a process of its
own, because loading the library defines entries in `global-map` that
every test in `menu-bar-tests.scm` would then see (importing it there
broke six of them). It pins the two menus, `access_keymap`'s coercion
for five item sequences - including one through the nested Replace
sub-menu - the separator's shape, and `menu-bar-final-items`.

## The cursor was black, always (2026-11-09)

Chris, after the theming work: *"the cursor color doesn't seem to change
with the theme."* It could not: `cursor-box-colour` in `pgtk.scm`
returned `(list 0.0 0.0 0.0)` with a note saying black is Emacs's
default. True of a light frame, and the reason every dark theme drew a
cursor nobody could see.

Emacs's chain is the `cursor` face's `:background` -> the `cursor-color`
frame parameter -> `x->cursor_pixel` (`x_set_cursor_color`, `xfns.c:1481`),
with `x->cursor_foreground_pixel` (the frame's background) as the ink a
filled cursor redraws the glyph in. The face is also a *standard* face -
`faces.el:2948` - black on a light frame and white on a dark one, before
any theme says otherwise, and it was missing from `faces.scm` entirely.

So: `cursor` and `mouse` deffaces added (`mouse` because the C's
guard reads it), and `cursor-box-colour`/`cursor-ink-colour` read the
faces, keeping the C's two adjustments - a cursor the colour of the
frame's background is replaced by the mouse pointer's colour, and the ink
falls back to the frame's background rather than to white.

**Departure**: the frame parameter is not carried. `xfaces.c` turns a
change of the face into `cursor-color` and the backend turns the
parameter into the pixel; this tree has no frame parameters, so the face
is read where the pixel is used. Same rule, one hop shorter.

Verified on a gtk editor under broadway: with `manoj-dark` (cursor
`orchid`) the cursor cell's pixel is `(218 112 214)`, which is orchid;
under `wombat` (cursor `#656565`) it is `(101 101 101)`. `faces-tests`
pins the face itself: black on a light frame, white on a dark one.

## The Buffers menu (2026-11-09)

The dynamic menu: its entries are the live buffers, most recently used
first, rebuilt by `menu-bar-update-hook` when the buffer or frame state
has moved. `frame-or-buffer-changed-p` (`dispnew.c:7048`) is the check -
a state list of frames and buffers with their read-only and modified
flags, compared and replaced.

**Placement departure**: that function is `dispnew.c`'s, but
`dispnew.scm` here is the display interface - a leaf that cannot see a
buffer - so it lives in `menu-bar.scm`, beside its only caller, as
`locate-file-internal` lives in `fileio.scm`.

Three tree-spellings again, each caught by running it:

- **A parameter's value is set by calling it** -
  `(*menu-bar-update-hook* (cons f ...))`, never `set!`. `set!` replaces
  the parameter object with a list, and the front end's
  `(*menu-bar-update-hook*)` then applies a list: "Wrong type to apply".
  And the setter's *result* is the unspecified value, so `((*p* v))` -
  the form I wrote twice - applies that.
- **`set!` answers the unspecified value**, so Emacs's `(eql limit (setq
  i (1+ i)))` has to take the count into a `let` first.
- **`define-key` prepends and the keymap's order is the display order**,
  so a menu built from a list is defined back to front: the command
  entries last in the display are defined first, then the buffer entries
  from the highest event down. Emacs's map is a vector followed by an
  alist and shows them in that order; here both are one alist.

The bar's menus are also defined in `menu-bar.el`'s own order -
buffer, edit, file - because it defines tools, buffer, options, edit,
file, help-menu and the prepending turns that into the display order
Help, File, Edit, Options, Buffers, Tools. With three of the six the bar
reads File, Edit, Buffers.

**Not here**: "Next Buffer" and "Previous Buffer" (window.c's
`switch-to-prev-buffer` - the per-window buffer history, which this tree
does not have) and the Frames sub-menu (frame parameters, `raise-frame`).

Verified live: the menu reads *beta, alpha, \*Schemacs\*, hello.txt --
/tmp/menutest/, \*Messages\* \*, \*scratch\*, --, Select Named Buffer...,
List All Buffers*, and activating `alpha` switched to it. Tests: the
menu's order, the entry's shape (`("name" . command)`, and the lookup's
answer being the command), and `frame-or-buffer-changed-p`'s
`(#f #t #f)`.

## A window's buffer history, and Next/Previous Buffer (2026-11-09)

`C-x <left>`/`C-x <right>` and the Buffers menu's Next/Previous entries
are `window.el`'s `switch-to-prev-buffer`/`switch-to-next-buffer`, which
walk a window's own record of what it showed before. Ported bottom up:

- **`<window>` gains `prev-buffers`/`next-buffers`** - `w->prev_buffers`
  and `w->next_buffers`, fields of the window since 30.1 - and
  `set-window-buffer!` **records the buffer it is leaving**, which is
  what the C's `Fset_window_buffer` does through `calln
  (Qrecord_window_buffer, window)` (`window.c:4475`). The recorder is
  `window.el`'s and lives above `frame.scm`, so it arrives through the
  seam `*record-window-buffer-function*`, as the message function does.
- **`record-window-buffer`, `switch-to-prev-buffer`,
  `switch-to-next-buffer`** in `window.scm`, with
  `set-window-buffer-start-and-point`, `unrecord-window-buffer`,
  `window-prev-buffers`/`-next-buffers` and their setters, and the three
  defcustoms (`switch-to-visible-buffer`,
  `switch-to-prev-buffer-skip`, `-skip-regexp`).
- `next-buffer`/`previous-buffer`, and `bindings.el`'s `C-x <right>`/
  `C-x <left>` pairs.

**Not carried**, each because what its test reads does not exist here:
every branch on a *window parameter* (`window-side`, `quit-restore`,
`quit-restore-prev`), on a *frame parameter* (`buffer-predicate`), the
minibuffer-window branch (the echo area stands in and is not a window),
the dedicated-window check, and `(buffer-list FRAME)` - there is one
buffer list here.

Verified live: from `two`, the menu's **Next Buffer** went to
`hello.txt` and **Previous Buffer** came back to `two`. A batch round
trip: switching a->b->c leaves `(b a)` as the window's previous buffers,
`switch-to-prev-buffer` goes to `b` and `switch-to-next-buffer` back to
`c`. `ncurses-editor-tests` pins both.

## Frame parameters, and `menu-bar-mode` (2026-11-09)

The blocker shared by the Frames sub-menu and `menu-bar-mode` was frame
parameters: `<frame>` had no `param_alist`. It has one now, with
`frame.c`'s four readers - `frame-parameters` (the stored alist plus the
computed keys: name, height, width, modeline, unsplittable, the buffer
lists, `menu-bar-lines`, tab bar, visibility), `frame-parameter`,
`set-frame-parameter` and `modify-frame-parameters` - and `frame.el`'s
two alists, `default-frame-alist` and `initial-frame-alist`, merged into
a new frame in that order (`initial-` first only for the first frame).

**Not stored**: `foreground-color`/`background-color`/`font` and the
window-system keys - the first three are the face machinery's and this
library sits below it, and the rest describe a display server this tree
does not model.

`menu-bar-mode` is a plain command, not the `define-minor-mode` the C
uses: `:global` is one of the keywords this tree's macro does not carry,
so it would have generated a buffer-local mode for a switch about every
frame. Its body is the C's - set `menu-bar-lines` on every frame, replace
it in `default-frame-alist` when it is there - and its numeric rule is
the macro's own (`easy-mmode.el:367`): `(not (and (numberp arg) (< arg
1)))`, so 1 or more enables and 0 or a negative one disables. Measured
against Emacs 31.1 first; my first attempt had `(not (zero? arg))`,
which turned `C--` *on*.

The gtk front end acts on the parameter where Emacs's
`x_set_menu_bar_lines` does: `pgtk-set-frame-menubar` takes the bar down
and stops when `menu-bar-lines` is 0, because running the hooks and the
rebuild after hiding would put it straight back. Verified live: the bar
is visible, `(menu-bar-mode -1)` + redisplay leaves `widget:visible` #f
and the hidden flag set, and `(menu-bar-mode 1)` brings it back.

Tests: `ncurses-editor-tests` pins the computed parameters, a stored
value winning, `modify-frame-parameters`, and the numeric rule
`(#f #t #f #t)` for 0, 1, -1, 2.

## "New Frame" killed the editor; Delete Frame was never greyed (2026-11-09)

Two reports from Chris. The first was mine to fix and is a port:
**`delete-frame-enabled-p`** (`menu-bar.el:2296`) counts the *visible*
frames and wants more than one, so the sole frame's Delete Frame item is
greyed rather than signalling when clicked. `frame-visible-p` is not
ported; nothing here iconifies, so every live frame is visible and the
count is the list's length. The item had `:enable #t`, written as a
placeholder and named as one.

A live check then showed it *still* disabled after a second frame: the
`:enable` expression names `delete-frame-enabled-p`, which was not yet in
`imports.scm`, and `menu-item-eval-property` turns an unbound variable
into nil - the item is quietly disabled. **A menu `:enable` that names a
function is only as good as the generated imports list.**

The second was a stack overflow. `(make-frame)` from the menu, or from
the REPL, overflows as soon as a second frame exists - and the trace led
to `frame-or-buffer-changed-p`:

- **Guile's `equal?` recurses into record fields.** A frame holds its
  windows and each window holds its frame, so `equal?` on two *different*
  frames walks a cycle until the stack runs out. Measured with two SRFI-9
  records pointing at each other: `eqv?` answers at once, `equal?` raises
  "Stack overflow". With one frame the old and new states were `eq?` and
  it answered immediately, which is why nothing showed until there were
  two. Emacs's C compares its state vector element by element with
  `BASE_EQ`/`EQ`, and `%same-state?` is that comparison.
- **The Buffers menu's selection closures were made fresh on every
  rebuild**, so the built `menu_items` array never compared equal, so the
  bar was rebuilt on every redisplay - and every rebuild laid its widgets
  out again. They are now made once per buffer and cached
  (`*menu-bar-buffer-commands*`), so an unchanged menu compares equal.

`*redisplay-in-progress*` (Emacs's `redisplaying_p`) also landed with
this: the gtk front end does not dispatch an event from a signal while a
redisplay is running, because the layout that a redisplay causes can fire
`size-allocate`, whose only effect is another redisplay.

Verified live: with one frame Delete Frame is insensitive, with two it is
sensitive; "New Frame" from the menu gives `F2`/`F3` and the editor stays
up.

## The minibuffer is a buffer, not a dynamic extent (2026-11-09/10)

Chris, using the editor: *"if I'm prompted in the minibuffer, I can ignore
that, click on a buffer and go on working, whereas in schemacs I'm stuck in
the minibuffer until I exit it"* - and then, once that was fixed, *"the
cursor should follow where I'm typing, but no it's stuck in the minibuffer"*.

**Emacs's minibuffer read does not own the keyboard; the minibuffer
*buffer* does.** `read_minibuf` makes that buffer current
(`Fset_buffer (minibuffer)`, `minibuf.c:794`) and gives it its keymap as a
*buffer-local* (`bset_keymap (current_buffer, map)`, `:906`). A click in
another window runs `Fselect_window`, which makes *that* window's buffer
current (`window.c:534`), so key lookup and `current-buffer` both follow
the click while the prompt stays on screen and on the stack
(`minibuf_level` still 1). `get_window_cursor_type` (`xdisp.c:34825`) then
puts the cursor in the selected window, because it is not
`XWINDOW (echo_area_window)`.

We had the keymap in a `parameterize` and the echo buffer shadowing
`current-editor` from below, so neither could move. Two changes:

- `read-minibuffer-1` sets the map on the **buffer**
  (`set!buffer-local-keymap ed ...`) and makes it current (`set-buffer ed`)
  inside the existing `(*current-buffer* #f)` unwind - which is the C's
  `Fset_buffer` + `record_unwind_current_buffer` pair;
- `current-editor` (`frame.scm`) is `(window-buffer (selected-window))`
  again, with no echo-area preference.

**The cursor** is gated on the current buffer being the prompt's, which is
this tree's stand-in for "the selected window is the minibuffer window".

**A bug this pass introduced and fixed in the same pass**: the gate was
written `(and A B (eq? ...))`, and `and` answers its *last* test - so
`reading` was `#t`, and `(buffer-pt #t)` killed `C-x C-f` with "Wrong type
argument ... #t". The buffer has to come last: `(and echo (eq? cur echo)
echo)`.

**Not reachable**: C-x o *back into* the prompt. `next-window`'s MINIBUF
nil "considers the minibuffer window only if active" (`window.c:2947`), so
Emacs's C-x o mid-prompt cycles through it - and this tree has no
minibuffer window at all. Named, not faked.


## The redraw skip I tried, and why it came out (2026-11-10)

Chris: *"surely if nothing changed the only incremental render you need to
do is the cursor."* Right, and it is Emacs's `w->redisplay` +
`window_outdated` (`window.c:231`). I ported the tick comparison
(`last_modified`/`last_overlay_modified` against `MODIFF`/`OVERLAY_MODIFF`,
new `overlay_modiff` field on buffer-text, `window-outdated?`), skipped an
unfresh window in `render-window!`, and measured **16 ms -> 5.4 ms** per
keystroke. It was correct on its own terms - fresh after a draw, stale
after an edit, verified live both ways.

**And it broke the editor**, because `render!` begins with
`clear-frame-area!`: a skipped window is not merely left alone, it is
*wiped*. The splash went blank and `mouse-tests` hung in the scroll loop.
Emacs can skip a window because it never clears the frame - it keeps a
glyph matrix per window and diffs it. The skip is therefore blocked on the
thing this file has named for two years: incremental redraw. Removing the
`clear-frame-area!` is the first step of that work, not a detail of it.
Reverted; the fields it added to `<window>` are left in place, unread.

# The isearch scan, and the row's glyphs (2026-11-14)

Chris: *"keep going because it's still dog slow"*, then *"but both are
still slow"*. This pass is the isearch keystroke and the redisplay's
allocation. Committed as `607f5a7`.

## Where an isearch keystroke's time goes now

In process (command loop, test display), a 240 KB file of "the quick
brown fox 888 ..." lines, searching for a pattern that ends in a
failure - the case every extended isearch pattern hits:

| | before | now |
|---|---|---|
| failing forward scan | 92.1 ms | **4.9 ms** |
| ... with case folding | 93.9 ms | **5.7 ms** |
| failing backward scan | 89.6 ms | **4.9 ms** |
| a match on the first line | 0.012 ms | 0.003 ms |
| four isearch keystrokes (three found, one failing) | 158 ms | **22.9 ms** |
| one plain self-insert key | 2.3 ms | 2.3 ms |
| GC over 50 keys | 33 ms / 10.3 MB | unchanged |

In a live tty editor a failing isearch key is ~14 ms: the scan ~8 ms of
it, render ~0.7 ms, lazy highlight ~0.1 ms, the rest the command loop
and the terminal.

## What made the scan cheap

`search_buffer` reads through `BUF_BEG_ADDR`/`GPT` macros that the C
compiler expands *into* the loop. The port called `buffer-text-ref` per
character - `%at`'s two record reads and the base subtraction - and
turned every character into a `#\char` to fold it before comparing.

- `buffer-text-store` and `buffer-text-gpt` are exported (they *are*
  `BEG_ADDR` and `GPT`); the scan hoists them and tests the gap once per
  character with a fixnum compare.
- The first-character prefilter compares code points: the needle's first
  character is converted once (its code point, downcase, upcase, folded
  form) and the per-character test is integer compares.

`boyer_moore` (`search.c:1746`) is deliberately **not** ported: for a
repeated-character pattern every character in the pattern has shift 1,
so the skip table degenerates to this scan, and that is the measured
workload.

## Two bugs this found

- The first prefilter folded with `char-upcase` alone. `char-upcase` of
  an uppercase needle is itself, so an uppercase needle ("BETA") never
  matched the lowercase text it folds against - a case-insensitive
  search silently found nothing. Both casings are compared now.
- The search tests inserted only at the end of the buffer, so the gap
  was never *before* the scan and the after-gap branch of the hoisted
  access was untested. `engine-tests.scm` has six gap-crossing cases
  now (`split-searchable` inserts at position 6).

## The redisplay's glyphs

`line-slice-glyphs` made a `<glyph>` record per cell per redisplay and
`extend-face-to-end-of-line` made a second vector plus up to 80 more per
row. Emacs's `append_glyph` writes into a pool allocated once. The rows
now keep their vectors and are written through (`%reset-glyph!`); the
padding appends into the same storage; blank rows keep theirs. Allocation
per 24x80 render: **433 KB -> 332 KB**, and a probe holds a slot's glyph
object across three renders and gets `eq?`.

`disp-table.scm` caches the one-character strings for code points below
256 - a representation departure (a `CHAR_GLYPH` in the C holds the
character) worth 2 KB against 1,920 allocations per redisplay.

**The remaining 332 KB is not glyphs**: it is the per-row lists
`line-texts-glyphs`/`line-texts-offsets` and the face runs. Emacs's
`display_line` appends glyphs straight from its iterator and builds no
lists; walking the line into the row in one pass is the next step, and
it is a rewrite of `build-row!`, not a change inside it.

## The traps this pass, again

- **A stale `.go` makes the editor interpreted, and that is 245 ms a key
  where the same code compiled is 14 ms.** Two "regressions" this pass
  were this and nothing else: the source is newer than the `.go` after
  an edit, the loader takes the source, and the A/B compares compiled
  against interpreted. Compile after every edit before measuring.
- **The pty latency harness is load-sensitive**: the same code measured
  13-16 ms and 27-32 ms per key in two runs. Use the in-process numbers
  for an A/B; use the pty only for the end-to-end feel.
- **`with-current-buffer` takes body forms.** The earlier headless
  isearch benchmark passed it a lambda, so it measured an *empty* buffer
  and its numbers were noise.
- **This editor does not echo a lone prefix on a terminal.** A pty check
  that waited for "C-x" after C-x timed out every time.
- `pty-check.py`'s `quit-after-prefix` now waits for the "Quit" it
  asserts on and tests for the WAIT marker's *absence*. Verified: with
  an impossible wait the marker is in the screen and the check fails.
- **`back-door` hung twice in one full battery and passed 5/5 alone.**
  The client was accepted and never greeted - the one-session-at-a-time
  REPL class this file already records. `check_back_door` opens a raw
  greeting socket (for the banner, which only the first client sees) and
  closes it immediately; the next client may connect before the editor
  has torn that session down. Not caused by this pass and not fixed.

# The search ring, the Gtk queue, and the extended face (2026-11-14)

Chris: *"C-s pressed twice will search on the most recent search value"*,
*"C-s is broken in gtk ... it works the first time"*, *"if I'm searching
for 888 ... a line that ends in 888 ... it paints it to the end of the
line"*, and *"do the next step"* - the row builder's one walk.

## What landed

- **The search ring** (`isearch.el:253-275`, `:1562`, `:1953`, `:3395`,
  `:639-640`): `C-s C-s` searches the ring's car, `M-n`/`M-p` walk it,
  `isearch-error` shows `[No previous search string]`, and the strings
  carry their case folding as a text property. **`M-s` is not history in
  Emacs** - it is the `isearch-toggle-*` prefix; measured, `C-s M-s C-g`
  says "M-s C-g is undefined". A repeat searches **from point**, not from
  `point - pattern length` (`isearch-search-from-point`): the backup is
  the rule a typed character needs and it made `C-s C-s` re-find the
  match point had just left.
- **The Gtk queue is drained.** The outermost command loop of that front
  end does not read, so a key queued because a command or a redisplay was
  running had no reader at all: it sat until the next prompt or isearch,
  or for ever. `pgtk-drain-queue!` dispatches the queue oldest first, as
  `kbd_buffer` is read. Reproduced with the display queue directly: three
  queued keys, one idle key - the idle key ran and the three stayed
  queued. **This was not the `C-s` bug** - a stranded key waits for the
  next key; Chris's C-s never came back.
- **`C-s` broken for ever on Gtk: Return is a *symbol*.** `keysym-event`
  makes Return the symbol `return`, and `function-key-map` (Return -> 13,
  TAB -> 9, escape -> 27) is applied by `dispatch-key` - which is *below*
  isearch's own read, so the search never saw RET: it exited through the
  other-key branch, which puts the key back on
  `unread-command-events`, and that list is only consumed by a *read* -
  which this front end's top level has none of. So the `return` stayed,
  every later search's first read answered it, exited and put it back:
  an infinite pushback. `C-g` could not help (the stale key is read
  first), and other commands worked (they do not read). `isearch-read-key`
  now applies `function-key-translate`, and `pgtk-drain-queue!` drains
  `*unread-command-events*` before the display queue. Verified by
  queueing Return as the real keysym: five searches in a row, all
  starting; before, 1 worked and 2-5 did nothing. `tty-editor-tests` feeds
  the symbol to a test display and pins both halves.
  **The reader is `*after-redisplay-hook*`**: the cursor-blink timer
  repaints from a Gtk source with no read anywhere, and a key pressed
  during that repaint had no collector either. The hook runs at the end
  of `redisplay-frames!` and the Gtk front end drains there; the drain is
  re-entrancy-guarded. Arming an idle/timeout source from `pgtk-enqueue!`
  does **not** work: measured, it wedged the calling REPL session and the
  source never ran.
- **`M-p` in isearch was two bugs.** `(kbd "M-p")` is a *sequence
  vector*, so `(eqv? key (kbd "M-p"))` was false for ever - the event is
  `(vector-ref (kbd "M-p") 0)`. And on a terminal `M-p` is ESC and `p`:
  the search read the ESC itself (below `read_key_sequence`) and its
  control-key exit ended the search, then the command loop ran an
  undefined `M-p`. `isearch-read-key` folds the ESC prefix into the meta
  event, as `read_char` does. Both measured at a pty: `C-s M-p` now walks
  the ring. **`M-s` is not history in Emacs** - it is the
  `isearch-toggle-*` prefix.
- **`extend_face_id`** (`xdisp.c:24429`, `xfaces.c:2527`): the row's
  padding uses the last glyph's face only when the faces at the row's end
  say `:extend`; `isearch` does not, `region` does, and a row ending at
  `point-max` uses the default. Measured on Emacs in a pty:
  `\e[36m\e[45m888\e[39;49m` then default padding. The one departure left:
  when `:extend` is true this fills with the last glyph's token, not the
  merge of the extending faces alone.
- **The row builder walks the line once** instead of building
  `line-texts-glyphs` + `line-texts-offsets`: 10.3 MB -> 8.4 MB per 50
  keystrokes, same wall time (both walk the same two cross-library
  accessors). `text-cells-width` was dead and is gone.
- **`faces-tests.scm` had been crashing in its second group for months**
  and `tools/run-suites.py` scored it green, because "Test suite
  finished" appears at the end of *each* group. The check now wants an
  `Entering`/`Leaving` pair for every group. Under the crash: the tests
  did not bind `*current-buffer*` (the overlay walk needs it - the
  renderer binds it in `display-window!`); an empty region split a run;
  three tests were outside any group, which this `srfi 64` cannot run at
  all after a group has ended; and one expected the symbol `cyan` where a
  colour is the string `"cyan"`. faces-tests: 16 -> 35 passing.

## Checks

`tools/pty-check.py` gained `isearch-ring` and `isearch-line-end`, each
seen failing with its fix reverted (and the ring check first "passed"
against the marker `[[harness: gave up waiting for b'C15']]` - the WAIT
trap, again: test the marker before the text it contains).
`pgtk-tests` pins the drain's order and that a deadline sentinel is
dropped. All 50 suites pass; faces-tests 35, pgtk-tests 108.

## Still open

- The Gtk drain is exercised by a unit test and by hand under `broadway`
  (the three-queued-keys reproduction). Nothing in the pty battery can
  click a Gtk window.
- `isearch-ring-adjust`'s `search-ring-update` nil branch
  (`isearch-edit-string`) is not carried: the ring always searches.
- The fill face when `:extend` is true is the last glyph's, not the
  extending faces' merge.
- Emacs 29+ makes the region highlight an *overlay* in Lisp; this tree
  merges the region in `attrs-at-buffer-position`. Only the empty-region
  case showed, and it is fixed.

## The battery after the Return fix (2026-11-14)

`tools/pty-check.py` on `4cb94f3`: **80/82**, with `query-replace-quit`
and `completion-ui` failing ("C-g during query-replace did not report
Quit"; "the completions window outlived the minibuffer"). Both pass
**3/3** when run alone, and neither touches anything this pass changed -
the battery's documented load/order flake class, not a regression.
`isearch-ring` (C-s C-s and C-s ESC p) and `isearch-line-end` pass.

# The keystroke was two guile-gi crossings (2026-11-15)

Chris: *"still dog slow"*. This pass measured **where** a Gtk keystroke goes
on a live window, and the answer was not the redisplay at all.

## The numbers, A/B on the same tree

Driving `dispatch-input-event` + `redisplay-frames!` from the back door -
which is the command and the redisplay a real key runs - 50 keys each,
240 KB file of 20,000-character wrapped lines:

| key | before | after |
|---|---|---|
| `C-n` | **10.30 ms** | **3.19 ms** |
| `C-f` | **9.85 ms** | **2.84 ms** |
| self-insert `a` | **38.50 ms** | **5.12 ms** |

"before" is the same tree with this pass stashed and compiled - not a
remembered number. The insert figures are why typing felt different from
moving: a full window rebuild of long wrapped lines was ~31 ms of it.

## What it was

`flush-display!` - the last statement of every redisplay - cost **7.1 ms**:

- `widget:queue-draw` (`gtk_widget_queue_draw`): **3.6 ms per call**. The C
  function through `dynamic-func`, on the pointer `pgtk-widget-pointer`
  already gives the popup and clip/board code, is **0.0003 ms** - four
  orders of magnitude. `flush-display!` calls it directly now.
- `pgtk-set-frame-menubar`: **3.0 ms**, 2.6 of it the `menu_items` parse,
  and it ran on **every** redisplay. Emacs reaches `set_frame_menubar` only
  when the display's `update_mode_line` says so (`xdisp.c:21522`).

**guile-gi calls on this machine cost ~3.5 ms each** - measured on the
method procedure itself, so it is the C wrapper and not GOOPS dispatch.
Anything per-keystroke that crosses guile-gi is a frame-rate bug; the fix is
`dynamic-func` on the pointer, the way pango and cairo already do.

## `update_mode_lines`, ported

dispnew has `update-mode-lines?`/`set-update-mode-lines!` beside
`windows-or-buffers-changed?`, because the two are **not** interchangeable:
the strong flag says no glyph matrix can be trusted (rebuild everything),
the weak one says only the mode line, frame title and menu bar have to be
recomputed. Set by `set-window-buffer!` (`window.c:4387`), `select-window`,
`set-frame-parameter` for `menu-bar-lines` (Emacs's parameter handler) and
`force-mode-line-update`; cleared with the other at `xdisp.c:18166`'s place.
Both menu-bar paths - Gtk's and the terminal's - now guard on it.

**`set-window-start!` is two functions now.** The DEFUN's body is the marker
pair plus `wset_update_mode_line` (`window.c:1969`), and the redisplay's
own scrolling writes `w->start` without it. `%window-start-set!` is the pair
and `scroll-to-cursor!`/`window-move-screen-lines` use it - before, every
recentring `C-n` re-parsed the menu bar.

## The cursor's row, from the matrix

`cursor-screen-position` asked `rows-above`, which **lays out every line
between the window start and the cursor** to count rows. Emacs asks
`w->current_matrix` (`try_cursor_movement`, `xdisp.c:19961`), whose rows
carry their start positions. `rows-above-in-window` is that walk; it answers
`#f` when the matrix is not what the screen holds, and the caller falls back
to counting lines, so it can only be a speed-up.

## Verified

- All 50 suites pass; `loadup-tests` 16 (the new exports are in the
  generated `imports.scm` - regenerate with `tools/gen-imports.scm` after
  adding one).
- Live, through the back door: the bar is built at startup (339 slots),
  `(menu-bar-mode -1)` hides it and `(menu-bar-mode 1)` **rebuilds** it,
  `set-face-attribute` on `mode-line` re-themes it, and
  `update-mode-lines?` goes `#f -> #t` on `select-window` and back to `#f`
  after `redisplay-frames!`.
- `tools/pty-check.py`: **82/82**, exit 0 - the first full green battery
  this tree has had (the last two were 80/82 and 61/62, both with the
  documented load flakes). Faster keys means the checks finish inside their
  own settle windows, so the flakes those notes blame on load are gone with
  the same change.

## Not carried from `bset_update_mode_line`

Emacs also raises the flag from `rename-buffer` (`buffer.c:1732`),
`reset_buffer_local_variables` (`buffer.c:3078` - so
`kill-all-local-variables`, i.e. every major-mode change) and
`set-buffer-multibyte` (`:3078` region). None is ported: the mode line is
*content-compared* when it is drawn, so a name or mode change shows without
the flag, and nothing in this tree's major modes installs a `[menu-bar]`
entry of its own yet - the one thing that would need it. Add them to
`(schemacs buffer)` when a mode does.

## Still slow, and what it needs

A self-insert is 5.1 ms, of which the insert is 0.004 ms: an edit
invalidates the window and **every row is rebuilt**. That is
`try_window_id` (`xdisp.c:22603`, ~790 lines) - reuse the rows above the
change, shift the ones below, rebuild what differs. It needs
`end_unchanged` bookkeeping (only `beg_unchanged` is carried today),
`row_containing_pos`, the matrix row shift and the `GIVE_UP` conditions.
Not started here rather than half-done.

# A retheme left the blank rows their old colour (2026-11-15)

Chris, retheming through omarchy: *"blank lines don't get rethemed, they
stay the old color... until I redraw, anyway."*

GNU Emacs's `realize_face` garbages the frame when it replaces a face's
realization (`xfaces.c:6252`); this tree's `set-face-attribute` only set
`windows_or_buffers_changed`. **A window-system frame's blank row carries no
glyphs** - `build-blank-row!` fills them on a terminal and the GUI paints
the remainder at draw time - so the row diff finds it equal and skips it,
and the old background stays on the surface. Text rows redraw (their face
tokens changed) and their tails are repainted with the new default, which
is exactly "blank lines only".

Fixed with `*frame-garbage-function*` in `faces.scm`, called from
`set-face-attribute` and installed by `frame.scm` (the seam pattern again,
because faces is below `<frame>`). Measured before/after on an offscreen
Gtk frame and through `load-theme` (wombat, tsdh-light). `pgtk-tests` has
the regression check and was seen failing without the fix.

**The general rule this is an instance of**: a row that carries no glyphs
cannot notice a change to what *would* be painted there. Anything that
alters the frame's appearance without altering glyph tokens has to repaint
those pixels explicitly.

# A quit from the read exited the editor (2026-11-15)

Chris: *"in tty editor, in dired, if I hold arrow down a while then quickly
hit C-g, the editor dies."*

A C-g is SIGINT, raised when the byte arrives, so behind a burst of keys
`quit-flag` is set while they are still being read - and the quit is then
raised by the read's own `maybe-quit`, inside the command loop's error
guard. **Emacs's `command_loop_2` (`keyboard.c:1159`) puts the loop
outside the guard**:

```c
  do val = internal_condition_case (command_loop_1, handlers, cmd_error);
  while (!NILP (val));
```

This tree had `(loop)` as the last form *of the guarded body*, so the
handler's value - the `"Quit"` message - became the iteration's value,
the loop returned, and the editor exited with status 0 and no message.
**Any** error raised by the read had the same effect, not just a quit.

Fixed by moving `(loop)` out of the guard; regression tests on both
sides: `tty-editor-tests`' `<quitting-display>` (a read that raises
`<quit-condition>`; the key scripted after it must still run - seen
failing without the fix with `actual-value: abc`), and `pty-check.py`'s
`quit-during-burst` (500 Downs + C-g, then M-x must prompt).

**Two traps in reproducing it, worth keeping**: a single write of
burst+C-g is *harmless* (SIGINT is raised before anything is read, so the
read answers `quit_char` at once), and a settled burst drains the queue
first. The C-g has to land mid-queue - the pty check does it with two
`nowait` writes and a `("sleep", 0.08)` between them. Also: a test display
method must be defined on the **imported generic** (`read-input-event`),
or `define-method` makes a fresh generic in the test's module and the
real dispatch never sees it (measured: the test "passed without the fix"
until the import was added).

# The echo row was redrawn every redisplay (2026-11-15)

A bare `redisplay-frames!` with nothing changed, offscreen Gtk, 810-line
Dired buffer: **2.1 ms and ~238 KB**. GNU Emacs's echo area is a *window*
whose row is diffed like any other; this tree drew the row every time -
the message, a run write, and 80 space glyphs filling it. `render!` briefly
compared a record (mode, prompt, echo-buffer tick, message, height,
width) and skipped an unchanged row - a stopgap, now deleted: the echo
area is a real window and its row goes through the glyph matrix. See the
handoff for that work below. Measured with the stopgap: 1.40 ms and
205 KB.

**Dired itself**, for the record: terminal, 800 files, C-n + redisplay
from the back door, **0.25-0.9 ms per key** in sustained scrolling, same
order as a text buffer. A 6 ms reading from the same harness was a
GC-heavy sample: at ~150-200 KB per redisplay the GC lands inside some
50-key batches, which is what "slow in bursts" feels like. The rest of
that allocation is `render!`'s fixed path (the frame row lists, the window
walk, the echo area) rebuilt per redisplay - incremental redraw, still the
named remaining gap.

# The echo area is a window, not a painted row (2026-11-15)

Chris: *"did I hear you say we draw to the echo area directly whereas
emacs uses a window?"*, then *"Fix it properly, like emacs"*. He was
right on both counts; DEPARTURES.md has the C it was measured against.

## What the echo area is now

`FRAME_MINIBUF_WINDOW` is an ordinary window drawn by `render!`'s window
loop, and it shows an ordinary buffer:

- **no prompt** → the frame's **echo buffer** (` *Echo Area 0*`), which
  `set!frame-message` writes the message into (`set_message_1`,
  `xdisp.c:13624`);
- **a prompt** → the minibuffer buffer, whose text *is the prompt plus
  what you typed*, with the `field` / `read-only` / `face
  minibuffer-prompt` properties `read_minibuf` puts there
  (`minibuf.c:858`). `minibuffer_unwind` (`:1231`) puts the echo buffer
  back on the way out.

Deleted with it: `render!`'s hand-drawn echo block, the
`*frame-last-echo-row*` record that made it cheap, the cursor's
`reading` branch, and **`*echo-area-prompt*`**.

## The three facts that fixed it

1. **The prompt is buffer text**, so `minibuffer-prompt-end` (a scan for
   the `field` property) and `minibuffer-cursor-column`
   (`current-line-display-column`, no prompt length added) became the
   C's answers rather than two spellings of one.
2. **A message during a prompt is an overlay** `after-string` at the end
   of the minibuffer buffer (`minibuffer-message`, `minibuffer.el:812`),
   not the echo area - the row is showing the answer being typed.
   `set-minibuffer-message` is installed as `set-message-function`, so a
   plain `message` during a prompt goes there too.
3. **`read-key`'s prompt is a message** with `cursor-in-echo-area`, which
   is what `read-char-from-minibuffer` and `read-quoted-char` now use.

`minibuffer-message`'s first argument is spelled **TEXT**, not MESSAGE:
Scheme is a Lisp-1 and a parameter called MESSAGE hides the `message` it
calls.

## Gotchas this cost

- **`overlays-at` leaves out a zero-length overlay at POS** - that is
  Emacs's own docstring (`buffer.c:3910`), not a bug - so the test helper
  that reads the message overlay has to use `overlays-in`. The renderer
  already did.
- **A `set!frame-message` with a non-selected frame** must not land in a
  shared buffer: ` *Echo Area 0*` is **one per frame** here, because this
  tree's messages are per frame and Emacs's two are global only because
  it displays them on the selected frame alone. A shared one shows one
  frame's message on another - which `pgtk-tests`' two-frame check pins.
- **`other-buffer` did not skip hidden buffers.** Emacs's
  `candidate_buffer` tests `BUFFER_HIDDEN_P` (name starts with a space,
  `buffer.h:1152`). Nothing noticed until a frame made ` *Echo Area 0*`
  and killing the last visible buffer then showed it.
- **`*cursor-in-echo-area*` moved to `dispnew.scm`** (`DEFVAR_BOOL`,
  `dispnew.c:7538`) - the renderer reads it and `window.scm` is above the
  renderer. `window.scm` re-exports it.
- The tests that fabricate a minibuffer (`with-minibuffer`,
  `prompt-frame`) now **insert the prompt** into the buffer, as
  `read-minibuf` does; a fabricated minibuffer with no prompt in it is no
  longer a minibuffer this editor can draw.

## The other half of putting the prompt in the buffer (2026-11-15)

`C-a` in a prompt went to position 1 - the start of the *prompt* - and
`C-k` killed it. Emacs stops at the field boundary, and the field
machinery was not ported (the old docstring on `line-beginning-position`
said "there are no fields here"). It is ported now, in `textprop.scm`
(the stickiness rule and the four property-change walks) and
`editfns.scm` (`get-pos-property`, `find-field`, `field-beginning`,
`field-end`, `constrain-to-field`), with `line-beginning-position` and
`line-end-position` calling it as the C does.

**The trap**: `bol`'s COUNT - which is what ESCAPE-FROM-EDGE comes from -
is `n - 1` for a number and 0 for a nil N, so it is `(beginning-of-line 1)`
that passes nil and `(beginning-of-line 0)` that passes t. Written as "N
is non-zero" the constraint appears not to work at all, because the
ordinary key is the case that passes nil.

Also worth knowing: `next-property-change`'s Lisp signature is
`(POSITION &optional OBJECT LIMIT)`, so `next-char-property-change`'s
`Fnext_property_change (position, Qnil, temp)` puts TEMP in the LIMIT
slot, not the OBJECT slot. Passing it positionally gave an
"expecting struct" error three functions away.

## Overlay strings are glyphs now (2026-11-15)

`minibuffer-message` is an overlay `after-string`, and the renderer had
never drawn one: `build-row!`'s own note said overlay strings were "not
carried here" because "nothing in this tree can make one yet". That
stopped being true, and the symptom was every TAB in a prompt saying
nothing - no `[No match]`, no `[Complete, but not unique]`, no
`[Sole completion]` - while the overlay itself was there and readable.

`line-slice-glyphs-with-strings` builds them **as glyphs in the row**,
which is what Emacs does (`get_overlay_strings` pushes the string onto
the iterator and `append_glyph` puts it in the row), so the diff sees
them and the matrix carries them. `build-row!` uses it only when
`row-overlay-strings` says the row has any, because the pool-reusing walk
is what keeps a keystroke allocation-free.

Two traps from the same pass:

- **`(vector-ref ovs i)` is `'()` for "no strings", not `#f`**, so
  `(car entry)` on it is "Wrong type argument ... ()". Test with
  `(pair? entry)`.
- **`*cursor-in-echo-area*` moved to `dispnew.scm` and `minibuffer.scm`
  was not importing it.** `read-char-from-minibuffer` raised on its first
  line, the command loop's guard turned that into "the command did
  nothing", and the pty check that failed was `save-y-n` - the `C-x C-c`
  prompt simply never appeared. The missing-import class again; a
  guarded error reads exactly like a key that is not bound.

## The two echo-area departures, and `called-interactively-p`

**The echo buffers are global now**, as Emacs's `echo_buffer[2]` are, and
they alternate (`with_echo_area_buffer` with WHICH = -1). The renderer
*swaps* the current one into the selected frame's minibuffer window for
the display and puts the window's own buffer back afterwards - which is
`with_echo_area_buffer`'s `wset_buffer`, and why a frame that is not
selected shows ` *Minibuf-0*` and nothing else. ` *Minibuf-0*` exists
now, made in `frame.scm` because a frame's minibuffer window needs it at
`new-frame-on` time and `minibuf.c`'s file is above that library.

**The minibuffer window grows**: `resize_mini_window`,
`grow_mini_window`/`shrink_mini_window`, `resize-mini-windows`
(`grow-only`) and `max-mini-window-height` (0.25) are ported. The text is
measured in rows, not pixels.

**`<frame>` lost its `echo-buffer` field.** That is a record change: clear
`~/.cache/guile/ccache` before believing any test result, or every library
compiled against the old layout reads the wrong slots - which showed up as
`(window-width w)` answering `""` and twenty unrelated test failures.

**`called-interactively-p` was one dynamic flag for the whole command**,
so `(font-lock-mode #t)` inside `dired-mode` echoed "Font-Lock mode
enabled" - which Emacs does not do, because it asks the *stack* whether
the function containing the call was the one `call-interactively` invoked.
There is no `frame-procedure` in this Guile, so the parameter holds the
command procedure and `(called-interactively? CMD)` is the exact answer;
`define-minor-mode` and `menu-bar-mode` pass their own commands.

## A compiled library folds its own `defvar`s (2026-11-15)

`menu-bar-tests` failed with three tests and passed with the same sources
when `keyboard.scm` happened to be *interpreted*. Measured:

    keyword.scm compiled:   (module-set! ... '*enable-disabled-menus-and-buttons* #t)
                            -> the variable reads #t, and `parse-menu-item`
                               still takes the #f branch
    keyboard.scm interpreted: -> the #t branch

**Guile's compiler treats a top-level definition that the module never
assigns as a constant and folds its reads**, so a `setq` (or
`module-set!`) from *another* module is invisible in a compiled build.
That is the same shape as the tree's own "a parameter is set by calling
it" rule, one level lower: a `defvar` meant to be `setq`-ed by a user's
init file is not a constant, but the compiler has no way to know.

The cure used here is one assignment in the defining library, which marks
it mutable:

    (define *enable-disabled-menus-and-buttons* #f)
    (set! *enable-disabled-menus-and-buttons* *enable-disabled-menus-and-buttons*)

Applied to the three variables the menu tests move
(`*enable-disabled-menus-and-buttons*`, `*menu-bar-final-items*`,
`*overriding-local-map-menu-flag*`). **Any other `defvar` that a user is
meant to `setq` needs the same**, or it only works in an un-compiled
tree - which is how this hid: the suites' answer depended on whether the
cache held a compiled copy of that one library.

This also explains an earlier phantom: the suites went green and red on
the same tree with different cache states.

# The syntax engine, and font-lock's syntactic pass (2026-11-15)

Chris chose "engine only first": port the syntax machinery and the
syntactic pass, with the faces, and wire it into what already has
font-lock defaults - no programming modes yet. The engine is what the
next pass (prog-mode, emacs-lisp-mode, scheme-mode, auto-mode-alist)
stands on.

## What landed

- **`schemacs/chartab.scm`** (NEW) - `src/chartab.c`, which is a
  file of its own in Emacs 31. The four-level 64/16/32/128 tree over
  characters 0..`MAX-CHAR`, with Emacs's `ascii` cache, the split of a
  slot into a sub-table on a write, parent inheritance, defaults, extra
  slots, `copy-char-table` and `optimize-char-table`. `chartab-tests`
  (24) pins every case against Emacs's own answers.
- **`schemacs/syntax.scm`** - the whole of `syntax.c` this pass
  needs, plus the `syntax.el` half, under one library because the two
  Emacs files' names would collide here:
  - the syntax descriptor (low 8 bits a class, high bits the comment
    flags) and the standard syntax table (`init_syntax_once`,
    character for character);
  - `syntax-table-p`, `syntax-table`, `standard-syntax-table`,
    `copy-syntax-table`, `set-syntax-table`, `char-syntax`,
    `syntax-class-to-char`, `matching-paren`, `string-to-syntax`,
    `modify-syntax-entry`;
  - `scan_words`, and with it the **end of mg's `inword`**: the word
    motions are `SYNTAX (c) == Sword` now, so `forward-word` in a
    fundamental buffer stops at `_` as Emacs's does;
  - `char_quoted`, `forw_comment`, `scan_sexps_forward` and
    `parse-partial-sexp`, with the level stack, the two-character
    comment constructs, fences and `commentstop` all as the C has them;
  - `with-syntax-table`, `syntax-ppss` (with the cache and the
    statistics vector), `syntax-ppss-flush-cache`,
    `syntax-ppss-toplevel-pos`, `syntax-ppss-context`,
    `syntax-propertize` (the function; the `syntax-propertize-rules`
    macro is not carried).
- **`schemacs/font-lock.scm`** - the syntactic pass:
  `font-lock-fontify-syntactically-region`, the default
  `font-lock-default-fontify-syntactically` (the loop Emacs writes
  around `parse-partial-sexp` with `commentstop` `syntax-table`),
  `font-lock-keywords-only`, `font-lock-syntax-table`,
  `font-lock-syntactic-face-function`, and
  `font-lock-default-fontify-region` wrapping its whole body in
  `with-syntax-table` and calling the syntactic pass before the
  keywords, as `font-lock.el:1202-1230` does. The
  `font-lock-*-face` deffaces were already in the file.
- `loadup.scm`'s `%editor-libraries` and the generated `imports.scm`
  carry `(schemacs chartab)`; `chartab-tests` and
  `syntax-tests` are in `tools/run-suites.py`.

## Verified against Emacs, not reasoned about

Every expectation in `syntax-tests.scm` (51) is Emacs 31.1's own
answer on the same buffer, measured with `emacs -Q --batch` first:
`char-syntax` for letters, `_`, `-`, space, parens, quotes, backslash,
newline, a control character and a multibyte character;
`string-to-syntax` for `w`, `(]`, `"`, `<` and `. 12`; `matching-paren`;
the word-motion positions (4, 8, 11, back 10); the full
`parse-partial-sexp` state table for a buffer holding a string and, with
`;`/newline installed as comment delimiters, for a comment and for a
C-style `/* */`; the `commentstop` `syntax-table` stop positions; and
the faces the syntactic pass leaves at every position of
`a ; foo\nb "s" c` - which match Emacs's `get-text-property` answers one
for one.

## The two bugs that mattered, both Elisp/Scheme seams

1. **`(or commentstop boundary-stop)` with the C's integer `commentstop`.**
   Emacs's `if (commentstop || boundary_stop)` tests an int; in Scheme
   **0 is true**, so every ordinary parse (commentstop 0) stopped dead at
   the first comment starter and no comment was ever scanned. The
   `'syntax-table` path worked by accident, which is why the first
   probes passed. Test the number: `(not (= commentstop 0))`.
2. **`nofence` was only set on the two entry paths.** The C sets it at
   `startinstring:` every time; a string opened *during* a scan kept the
   old value, so its closing quote was never recognised and the rest of
   the buffer was "inside a string". `state->instring` and `nofence` are
   one fact and are now set together.

## A property of Emacs worth knowing, found by the tests

**A buffer's syntax table starts as the standard table *object*.** A
`modify-syntax-entry` with no table argument in such a buffer writes into
the global standard table, and every buffer after it sees the change -
Emacs's behaviour, not a bug (`reset_buffer_local_variables` installs the
same object; modes always `make-syntax-table` first). Two test groups
that each modified `;` interfered until each installed
`(copy-syntax-table (standard-syntax-table))` first. The same fact means
`syntax-tests.scm`'s groups must not assume a pristine standard table.

## Not carried, and what each would take

- `forward-comment`, `scan-lists`, `scan-sexps`, `back_comment`,
  `find_defun_start` - the scanning half that `forward-sexp` and
  `comment-dwim` use; the syntactic pass does not need them.
- `skip-syntax-forward`/`-backward`.
- `syntax-propertize-rules` (the macro) and `syntax-propertize`'s
  `syntax-multiline` extension; a mode can supply its own
  `syntax-propertize-function`.
- The delimiter-face branch of the syntactic pass: it needs
  `comment-start-skip`/`comment-end-skip`, which are newcomment.el's.
- `word_boundary_p` answers false always (no `char-script-table`).
- **The modes themselves** - `prog-mode`, `emacs-lisp-mode`,
  `scheme-mode`, `auto-mode-alist`/`set-auto-mode`, and
  `global-font-lock-mode`. Until they land, nothing but a mode that sets
  `font-lock-defaults` by hand (dired, which sets keywords-only) uses the
  new pass; `syntax-tests.scm` drives it directly.

## Next

The mode pass, bottom up: `prog-mode` (prog-mode.el), then
`lisp-mode.el`/`elisp-mode.el` and `scheme.el`'s keyword tables, then
`auto-mode-alist` with `set-auto-mode` so `C-x C-f x.scm` picks the mode
and the colours appear. `c-mode` (cc-mode) remains its own project.

# The modes, and the first colours (2026-11-15)

Chris chose "engine only first", and this is the pass the engine was for:
`prog-mode`, `lisp-data-mode`, `lisp-mode`, `emacs-lisp-mode`,
`lisp-interaction-mode` and `scheme-mode` are in, `auto-mode-alist` with
`set-auto-mode` picks a mode from a file's name (or its `-*-` tag), and
`global-font-lock-mode` is the switch - so opening a `.scm` or `.el` file
now colours keywords, function names, comments and strings.

## What landed, and where

| Emacs | here |
|---|---|
| `lisp/progmodes/prog-mode.el` | `prog-mode.sld` |
| `lisp/emacs-lisp/lisp-mode.el` | `lisp-mode.sld` |
| `lisp/progmodes/elisp-mode.el` | `elisp-mode.sld` |
| `lisp/progmodes/scheme.el` | `scheme.sld` |
| `files.el` 3040-3910: `normal-mode`, `set-auto-mode` and the four alists | `files.sld` |
| `font-core.el`'s global half | `font-core.sld` |
| `subr.el`'s `make-syntax-table`, `add-hook`, `remove-hook`, `assoc-default`, `string-suffix-p` | `subr.sld` |

Tests: `lisp-mode-tests.scm` (33) - the syntax tables against Emacs's own
`char-syntax` answers, the faces at named positions, the mode-local
variables, and five `set-auto-mode` cases through `find-file-noselect`.
`font-lock-tests.scm` grew the setup-flag reset that a reused test buffer
needs now that `font-lock-set-defaults` has Emacs's "already done" guard.

## The three engine fixes that had to come first

Read DEPARTURES.md's 2026-11-15 section; in one line each:

1. **`\w`, `\W`, `\sC`, `\SC` are the syntax table's classes now**, built
   by enumerating the table into a glibc bracket expression. Before, `\w`
   was glibc's `[[:alnum:]_]` (which matches `_`, which Emacs's standard
   table says is *symbol* syntax) and `\s` was rejected outright - so no
   Lisp keyword regexp could match.
2. **Match-data groups are renumbered through a mapping** recorded at
   compile time, so a shy `\(?:` or numbered `\(?1:` group no longer
   shifts every `(SUBPEXP FACE)` entry in a keyword table.
3. **`\_<`/`\_>` are approximated by `\<`/`\>`** - named, with the exact
   case where they differ.

## Wiring a mode now

`define-derived-mode` takes the child's syntax table as its *sixth*
element, because Emacs's macro invents `CHILD-syntax-table` and a
`syntax-rules` template cannot:

    (define-derived-mode (scheme-mode prog-mode "Scheme" scheme-mode-map
                                      scheme-mode-hook
                                      scheme-mode-syntax-table)
      "doc" (scheme-mode-variables))

The mode installs it before the body, as `derived.el` does.

## What is not there, and what each needs

* `forward-sexp`/`scan-sexps`, `beginning-of-defun`, `fill-paragraph`,
  `syntax-propertize-rules`: the four things the mode *bodies* still
  name - indentation, filling, `C-M-x`, and `#;`/`#|` propertizing.
* `rx`: the Lisp keyword tables are transcribed from Emacs's expansion
  rather than rebuilt; a mode that wants `rx` needs the macro.
* `text-mode`: `.txt` files say "Ignoring unknown mode `text-mode'" and
  stay in fundamental-mode. `text-mode.el` is small and is the next
  cheap mode.
* `syntax-propertize` for `#(...)`/`|...|`: without it those parse as
  several expressions.
* `c-mode` (cc-mode): unchanged, its own project.

## The method notes worth keeping, again

* A `when` whose test fails answers the *unspecified* value, which is
  true in Scheme: `(if (when TEST BODY) (loop) ...)` is an infinite loop.
  The C's `when` answers nil. This cost the auto-mode walk.
* `(cdr #f)` is an error; Elisp's `(cdr nil)` is nil. `major-mode-remap`
  had to test the cell.
* **Editing a big `syntax-rules` macro by string replacement ends in the
  paren swamp.** The way out that worked here: extract the macro's line
  range, write the replacement whole, and verify with
  `guile --r7rs -c '(read ...)'` that the library body has the expected
  number of top-level forms before compiling.
* `tools/run-suites.py` takes ~10 minutes; its output is buffered to the
  end, so run it in the background and keep working on non-`.scm` files.

# The prompt after `C-x 1`, and modes that load themselves (2026-11-15)

Chris reported, from a two-window start (a file on the command line and
the splash below it): *"C-x 1, then C-x f ... the 'Theme set to
osaka-jade' remains there and the cursor jumps to after that message,
and if I type into it the characters seem invisible."*

**The cause was `delete-other-windows` rebuilding `frame-windows` as
`(list window)`.** The minibuffer window lives in that flat list (the
echo area has been an ordinary window since 2026-11-15), so the frame
was left with no window at the bottom: `render!` walks
`(window-list frame #t)`, the row kept whatever was painted there last,
and the cursor came from that window's stale matrix. Fixed by keeping
the minibuffer window in the list. `tools/pty-check.py`'s
`prompt-after-delete-other-windows` is the regression check - it fails on
the old code with the mode line on the last row.

**Any command that rebuilds the frame's window list has to keep the
minibuffer window in it.** `delete-window` and `split-window` already
did; `delete-other-windows` did not. A window operation that touches
`frame-windows` should be checked against `new-frame-on`'s shape
(`(list window mini)`).

The same pass found that **`auto-mode-alist` needs autoloads**:
Emacs's names are all autoloadable, this tree's are not. `files.sld` has
a six-entry `%mode-autoloads` table and `%mode-function` loads a mode's
library with `resolve-module` on first use - without it, opening a `.txt`
in a real editor stayed in fundamental-mode, because nothing had
imported `text-mode`. Add an entry there when a new mode lands.

**Two things I first did wrong here, both called by Chris.**

`delete-other-windows` was fixed the first time by keeping the
minibuffer window in a flat `frame-windows` list - a hack over the
representation. The C has `f->root_window` (the body tree) and
`f->minibuffer_window` separate; the frame record already had both
fields, and the departure was `new-frame-on` putting the window in
*both*. Now `frame-windows` is the body only and `window-list` composes
the minibuffer window in by `window_list_1`'s MINIBUF rule.

And "Ignoring unknown mode" was briefly *suppressed* for
`auto-mode-alist` entries because the message created `*Messages*` -
which reordered the buffer list under a tty test and made a Buffer Menu
test loop. That silenced the symptom of the real gap: nothing
autoloaded a mode, so a `.txt` stayed in fundamental-mode. With the
autoload table in place Emacs's message is back, and the suites are
green with it.

`text-mode` is in (`.txt` files), and `global-font-lock-mode` is turned
on in `startup.sld`'s boot, where Emacs's `:init-value` would have put
it.

# The sexp, list and defun commands (2026-11-15)

Chris's list of motions, less the three indentation commands. Everything
below is `39cdccd`, and **every expectation in `lisp-tests.scm` is Emacs
31.1's own answer**, measured with `emacs -Q --batch` on the same text.

## What landed, and where

| Emacs | here |
|---|---|
| `syntax.c:2660` `scan_lists` | `syntax.scm` `%scan-lists` |
| `syntax.c:695` `back_comment` | `syntax.scm` `%back-comment` |
| `syntax.c:585` `find_defun_start` | `syntax.scm` `%find-defun-start` |
| `syntax.c:3096` `backward-prefix-chars` | `backward-prefix-chars` |
| `syntax.c:1660` `skip_chars` | `%skip-chars` (ranges and `[:class:]`) |
| `syntax.c:2436` `forward_comment` | `forward-comment` |
| `lisp.el` | **`lisp.scm`** (new) - forward-sexp, backward-sexp, mark-sexp, forward-list, backward-list, down-list, up-list, backward-up-list, kill-sexp, backward-kill-sexp, beginning-of-defun (+ `-raw`, `-comments`), end-of-defun, mark-defun, insert-pair, insert-parentheses, transpose-sexps |
| `elisp-mode.el` eval commands | `elisp-mode.scm` `eval-last-sexp`, `eval-print-last-sexp`, `eval-defun` |

Both defun commands are **lisp.el's in Emacs 31**, not `editfns.c`'s as
they were in older versions - so `lisp.scm` is where they went.

## Four things worth knowing before the next pass

1. **The syntax classes are *values* here, not enum constants.** A `case`
   over them compares the number against the *symbol* and silently takes
   the `else` branch: the first `%scan-lists` walked a whole buffer one
   character at a time and never opened a list. Every dispatch on a
   class is a `cond` with `=`/`memv`. This bit twice - `%scan-lists` and
   `%back-comment` both.

2. **`scan-error` is a condition record now** (`<scan-error>`, with the
   raw message and the two positions, as `xsignal3`'s data is).
   `error-message-string` and keyboard's reporter both know it and render
   `Scan error: "Unbalanced parentheses", 1, 5`, which is what Emacs
   prints. `condition-case (scan-error ...)` becomes `guard` +
   `scan-error?`, which is how `forward-sexp` says "No next sexp".

3. **`re-search-backward` with a negative COUNT searches forward.** The C
   is `n = direction * count` (`search_command`, `search.c:1040`), and
   `beginning-of-defun-raw` passes `-arg` for its forward direction.
   Ours ignored the sign, which left `(end-of-defun 2)` stopping one
   defun short.

4. **`skip-chars-forward`/`-backward` were a membership test** -
   `(memv c (string->list set))` - so no ranges and no `[:space:]`.
   `mark-defun` ends with `(skip-chars-backward "[:space:]\n")`.
   `%skip-chars` now parses ranges, backslash escapes, leading `^` and
   the `[:class:]` vocabulary; the C's `fastmap`/`char_ranges` are an
   optimisation and the membership test is the same test.

## Deliberately not carried

* **`defun-prompt-regexp`'s non-nil path is carried but never taken** —
  nothing here sets it — and `beginning-of-defun-raw`'s
  `wrong-number-of-arguments` fallback catches *every* error, because
  this tree has one error condition type.
* **No narrowing**: `up-list-default-function`'s `narrow-to-region` arm
  and `beginning-of-defun-raw`'s `save-restriction`/`widen` have nothing
  to do here. `no-syntax-crossing` still behaves, via the error arm.
* `delete-pair`, `kill-backward-up-list` (`thing-at-point`),
  `mark-defun-back` (no command symbols), `eval-sexp-add-defvars`,
  `elisp--eval-defun-1` (Scheme has no `defvar`), `lexical-binding`,
  `macroexpand-all`, and the print truncation variables.
* **`elisp--preceding-sexp`'s Emacs-reader syntax** — the quote
  stripping, `?\e`, `#s`, `#N=` — because the reader is Scheme's, the
  same departure `eval-expression` carries.

## Still to do

`indent-sexp` (lisp-mode.el), `indent-region` (indent.el) and
`move-past-close-and-reindent` (lisp.el) all rest on
**`calculate-lisp-indent`** and `lisp-indent-line`, the Lisp indentation
engine: `parse-partial-sexp` (ported) plus `lisp-indent-function`, the
`common-lisp-indent-function` specform table (cl-indent.el), and
indent.el's `indent-line-to`/`indent-according-to-mode`. That is a pass
of its own and was not started.

# The syntax-table cache, and C-g inside a long command (2026-11-15)

Chris: *"I tried a big file, schemacs/xdisp.scm and did a C-M-f to
go to the end... works, that's good. Then I did a C-M-b which should go
back to the beginning.. it gets stuck, at that point nothing can recover,
not even C-g"*, then *"Even given a problem with the scanner, I'm curious
why C-g can't recover"*. Both halves are fixed; DEPARTURES.md has the C
each was measured against.

## What was wrong

1. **`gl_state` was not ported.** `syntax.c` reads the `syntax-table`
   text property through the interval cache in `syntax.h`'s
   `struct gl_state_s`: the interval the last lookup landed in, and the
   run `b_property'..`e_property` over which its table applies, walked
   one interval at a time. What stood here was a forward-only run cache
   built on `next-single-property-change`, which (a) walks every interval
   forward to the end of the buffer when the property it asks about never
   changes - which is what a font-locked buffer is - and (b) is never hit
   by a backward scan at all. `C-M-b` on `xdisp.scm`: **144 s -> 0.92 s**
   headless, 1.17 s in the live editor. The fix is `%update-syntax-table`
   and friends in `syntax.scm`, a direct port of `update_syntax_table`
   (`syntax.c:336`).

2. **Nothing outside the read ever looked at `quit-flag`.** `maybe-quit`
   lived in `keyboard.scm` and its only caller was `read-key-event`, so a
   C-g pressed *during* a command set the flag and no one noticed. That
   is why the slow scan was also unrecoverable. `maybe-quit` and
   `rarely-quit` are `command.scm`'s now (`keyboard.scm` re-exports
   them), and the scan loops call `rarely-quit` where the C calls it.

## Before touching the scanner again

* **`%setup-syntax-table` is `SETUP_SYNTAX_TABLE`, and every entry point
  that reads syntax must call it.** `scan_words` never did - the C does
  (`syntax.c:1473`) - and that only showed once the cache became
  long-lived: four word-motion tests failed. A scan function that starts
  reading syntax without it will read the previous buffer's table.
* **`%syntax-entry-in` is the only place `SYNTAX(c)` is read**, and it
  applies `UPDATE_SYNTAX_TABLE` itself. If you add a scan, read characters
  through `%class-in`/`%code-in` and the cache comes with it; if you add a
  loop that could run long, add `rarely-quit` to it.
* **A timing regression test is in `syntax-tests.scm`**: 40 000 chars in
  4 000 `face` intervals, scanned backward, must land right and take under
  2 s (it takes 21 ms; it took 11.9 s before). If that test starts
  failing on time, the cache is being missed again.

## Method notes worth keeping

* **`internal-time-units-per-second` is 1 000 000 000 here.** A first
  measurement divided `get-internal-real-time` by 1000 and read 1.4 s as
  1 379 343 855 ms, i.e. as a hang. Print the unit before trusting a
  duration.
* **A pty check that presses C-g must write `\x07`, not `\x03`.** The
  tree sets `VINTR` to C-g; `\x03` is an ordinary C-c byte. Measured both
  ways: `\x03` during a 74-second REPL loop was consumed as a keystroke
  and the loop ran to completion; `\x07` raised `quit` in 25 ms.
* **`os.kill (pid, SIGINT)` is a fast way to test the quit path without
  a terminal** - it proved the handler/flag/`maybe-quit` chain while the
  pty byte was still being written to the wrong character.
* **A C-g sent to an idle editor is eaten by the read.** A test that
  wants to interrupt a *command* has to wait until the command is
  running, or the key becomes the next command's quit.

## Still open

The remaining cost is per character, not structural: a backward scan of
`xdisp.scm` is 1.17 s where Emacs is milliseconds. Each character costs a
`%syntax-entry-in` (cache hit + `char-table-ref`), a `fetch-char`, and -
in `%scan-lists` - **two** lookups, because `b-top` reads `%code-in` and
then `%syntax-multibyte` re-reads the same entry. That is a constant
factor to attack in a performance pass, not a departure.

## Opening a big file: the font-lock searches (same day)

Chris: *"do you realise just opening xdisp.scm hangs the editor? and makes
the CPU go into overload"*. 23 s at ~140 % CPU, and 13.5 s of it was
`font-lock-fontify-keywords-region`.

**Guile's `regexp-exec` costs time proportional to the length of the
string it is handed** - 0.9 µs on 257 characters, 920 µs on 257 000, and
6.4 ms for a match at offset 0 of a 257 000-character string. So a search
must not be handed the buffer, and it must not be handed the whole range
it may search either. `%re-search` now searches a window of 512
characters that doubles until the answer cannot depend on where it ends
(a match ending at the window's edge is re-asked on a wider window,
because `$` and `\b` at a copied edge are not the buffer's). Measured:
keyword pass 13 455 -> 227 ms, opening the file 23 s -> under 1 s.

Two things to remember before touching searches:

* **`%re-search-forward-1` and `%re-search-backward-1` are the two
  directions** (they were one block of `%re-search` and the parens were
  not worth it). Both answer `(MATCH START END BASE)`, and BASE is what
  `match-data--translate` adds - the window's first position, not zero.
* **The window's start is one character before the search start** so that
  `^` is judged against the real character in front of it; `\=` and `\'`
  (which could tell a window from the buffer) are refused by
  `%emacs-ere`, and that is what makes the window sound.

A `%search-text` cache of the whole buffer, keyed on
`buffer-chars-modified-tick`, was tried first and is *wrong* for this
engine - it is in this file's history and in DEPARTURES.md with the
numbers.

**The window is a copy the C does not make, so it is checked against
Emacs rather than reasoned about.** `tools/` does not carry the harness
yet, but the recipe is: generate ~500 random (text, point, bound,
pattern, direction) cases, emit them both as a file this tree's
`re-search-forward`/`-backward` reads and as an elisp file for
`emacs -Q --batch`, and diff the answers. That found 13 wrong answers in
`HEAD`'s search, all of them `$`/`\b` judged against the edge of the
copied text, and it is how the "one character past the bound" rule and
the backward "ask again with the text ending at point" rule were
justified. The current code matches Emacs on all 500.

**Before touching the window, know what the three edges are for:**
* the window starts one character before the search start, so `^` is
  judged against the real character in front of it (`%bol-flags`);
* it ends one character past the bound, so `$` and `\b` are judged
  against the real character after it;
* a backward search whose longest match runs past point asks again with
  the text ending at point, because the C's engine matches against
  `stop`.

**`looking-at` is the same shape and had the same cost** - it copied the
whole buffer per call (300 calls on a 257 KB buffer: 7.7 s). It reads a
window now, and `search-tests.scm` pins it with a time bound.
`looking-back` still copies a substring per start position it tries; it
is walked from point backward and is not on a hot path, but it is the
next one to look at if a search ever shows up in a profile.

# The Lisp indentation engine, and the five primitives it broke open
# (2026-11-15)

Chris: *"keep porting those sexp functions, you didn't finish yet"* -
`indent-sexp`, `indent-region` and `move-past-close-and-reindent`, the
three that rest on `calculate-lisp-indent` and `lisp-indent-line`. They
are in, with the whole engine under them (`lisp-mode.el:880-1500`),
`indent.el`'s layer and `newcomment.el`'s `comment-indent`. DEPARTURES.md
has the four engine departures and every scanner fix; this is the shape
of the work and what it taught.

## The method that found everything: indent a file both ways and diff

`emacs -Q --batch` with `(indent-region (point-min) (point-max))` on a
copy, this tree's `indent-region` on the same text, `diff`. That is the
whole harness - no unit test, no invented expectation - and it turned a
"probably right" engine into a list of named failures and then into **105
of the 110 files** under `lisp/emacs-lisp/` exact. The five that remain
are places where Emacs's `indent-region` disagrees with its own
`calculate-lisp-indent` (measured on two of them); DEPARTURES.md names
them. Use it before believing
any indentation result: an engine can be plausible line by line and
wrong in aggregate.

The corpus runner is three lines and worth rebuilding when needed:

    for f in /path/*.el; do
      guile --no-auto-compile -L . -L "$SITE" -s /tmp/ind-file.scm "$f"
      cp "$f" /tmp/em-x.el
      emacs -Q --batch --eval '(progn (find-file "/tmp/em-x.el")
        (emacs-lisp-mode) (indent-region (point-min) (point-max))
        (save-buffer) (kill-emacs))'
      cmp -s /tmp/em-x.el /tmp/ours-out.el || echo "DIFF $f"
    done

## What the diff found, in the order it found it

1. **The engine's final `cond` was inside `(if retry ...)`.** Every
   top-level line answered `#f` instead of `0`.
2. **The `lisp-indent-function` *variable* defaulted to `#f`.** The hook
   never ran, so every `(defun ...)` body aligned to column 7 rather than
   2. Its `defcustom` initial value is the procedure itself.
3. **The properties the hook reads are data Emacs builds at macro
   definition time.** 303 of them are transcribed now; the transcription
   must ask `(function-get SYMBOL 'lisp-indent-function 'macro)` **one
   symbol at a time**, or it picks up macros from libraries a real Emacs
   has not loaded - which reads as a *regression* on the very file that
   defines them (`inline--letlisteval`).
4. **`fixup-whitespace` had lost its `\s(`/`\s)` classes** (they became
   expressible on 2026-11-15). `M-)` showed it: `(a b )` for `(a b)`.
5. **The scanner did not consume the character after `\`.** `(a \" b)`
   was "inside a string" from the quote onwards, which is why `pp.el`'s
   lines 216-238 all answered `nil`. The C's `case Sescape:` ends
   `goto startquoted`, and `startquoted` does `INC_FROM` before
   `symstarted`.
6. **`syntax-ppss-toplevel-pos` was a `cond` over the depth** where the C
   is `(or (car (nth 9 ppss)) (nth 8 ppss))`; its `(> (nth 4 ppss) 0)`
   raised on a `t`.
7. **`syntax-propertize` needed `save-excursion`** (the mode's function
   does `(goto-char start)`), needed `--done` set *before* the function
   runs (recursion guard), and `syntax-propertize-function` is
   **buffer-local**, not a parameter.
8. **`parse-partial-sexp` propertizes as it scans**
   (`update_syntax_table_forward` -> `parse_sexp_propertize`), and
   accepts a *short* OLDSTATE - `lisp.el` passes a nine-element one.

Every one of those is a primitive, and every one was invisible until
something was built on top of it. This is the "port the primitives
first" rule paying out: the same session that ported the engine also had
to fix the scanner twice, `syntax-ppss`, `syntax-propertize` and
`parse-partial-sexp`'s OLDSTATE.

## `,@` is why `syntax-propertize` had to be wired at all

`emacs-lisp-mode`'s syntax table gives `@` plain symbol syntax and the
mode propertizes `,@` as a quote (`elisp-mode.el:259`). Without it, every
backquote splice in a file indents two columns out - `cl-macs.el` alone
was 15 lines. `syntax-propertize-rules` (the macro) is not ported, so
`elisp-mode-syntax-propertize` writes the four rules out as **one**
alternation. Four separate scans cost 35 s on a 170 KB file: each restart
threw `syntax-ppss`'s cache backwards. The single scan costs 5 s, and
the whole-file indent is now ~5 s per 170 KB.

## The harness trap that cost the most

`grep -v "note: source"` on a run hides **"source file X newer than
compiled"** - which is Guile telling you it is about to load *source*
rather than the `.go`. Several A/B measurements in this pass compared
compiled against interpreted and a "fix" looked like it did nothing.
Compile the tree (`guile -L . -L "$SITE" -c '(compile-file "f")'`) and
do not filter that note away while measuring.

## What to do next on this file

* `cl-indent.el`'s `common-lisp-indent-function` and `scheme.el`'s
  `scheme-indent-function` are the two tables modes still want, and both
  are pure data transcribed the way the property table was.
* `syntax-propertize-rules` wants `regexp-opt-depth` and
  `subregexp-context-p`; until then `lisp-mode-syntax-propertize`'s
  `|...|` rule is missing.
* `indent-pp-sexp` needs `pp`.

## The scanner and `syntax-ppss` were where the remaining bugs were
## (2026-11-15, second pass)

After the engine matched Emacs line by line, three more failures came out
of the *same* differential, and all three were in primitives:

1. **`syntax-propertize` propertizes on every character** as a scan runs
   (`update_syntax_table_forward` -> `parse_sexp_propertize`), not only
   when the interval run changes. Checking only on a run change left a
   file half propertized - `syntax-propertize--done` stuck 300
   characters behind the scan, `vtable.el` off by two columns - and the
   half-propertized state was 12x slower than the correct one. The
   truncation branch needs `e_property_truncated` or the next walk off
   the cache says "Error in syntax_table logic for to-the-end
   intervals".
2. **`syntax-ppss`'s cache is in decreasing position order**, replaced or
   inserted by gap; the port pushed every entry at the front. With that,
   plus `(setq pt-min ...)` written as a `set!` inside an `and` (it
   answers the *old* value here), plus the missing `pt-min` rebinding in
   the `else` branch, running `calculate-lisp-indent` line by line over
   `subr-x.el` raised "End position is smaller than start position".
3. **`scan_sexps_forward`'s `Sescape` path goes to `startquoted`**, which
   consumes the quoted character; going straight to `symstarted` made a
   `\"` in a character literal open a string, and `pp.el`'s lines
   216-238 all answered nil.

`lisp--local-defform-body-p` is carried after all (it was dropped in the
first pass): it is what makes a `cl-flet`/`cl-labels` body indent as a
definition, and `cl-extra.el`, `ert.el`, `eldoc.el`, `generator.el` and
`comp.el` all depend on it. Two traps in porting it: its `when`s must
answer `#f` (the caller is an `if`), and Emacs's `(read (current-buffer))`
leaves point past the symbol - a string-port read does not, so the port
follows it with `(forward-sexp 1)`.

**A pty check written for `C-M-q`/`M-)` was wrong twice before the
editor was**: it sent the literal text `C-s` instead of control-S, and it
pressed `M-)` from point 1, where Emacs signals "Unbalanced parentheses"
too. Both are cheap mistakes to make when the harness speaks bytes.

# The colourising pass: `lisp-el-font-lock-keywords-2` in full (2026-11-15)

Chris: *"when you finish that keep working on the colorise mode for lisp and
elisp."* The level-2 keyword tables are now Emacs's whole list, and the
faces they produce match Emacs 31.1 **run for run** on 22 of 24 files
under `lisp/emacs-lisp/` (the harness is `/tmp/faces.el` and
`/tmp/ours-faces.scm`: `get-text-property`/`next-single-property-change`
over the whole buffer on both sides). DEPARTURES.md has the C each fix was
measured against.

## What landed in `lisp-mode.scm`

- `%lisp-el-special-forms-and-macros` (311 symbols), `lisp--el-funcall-position-p`,
  `lisp--el-match-keyword`, `lisp-mode--search-key`, `elisp--font-lock-backslash`,
  `lisp--match-hidden-arg`, `lisp--match-confusable-symbol-character`, and the
  doc-string cluster (`lisp-doc-string-elt-property`, `cl--defmethod-doc-pos`,
  the 64-entry table, `lisp-string-in-doc-position-p`,
  `lisp-string-after-doc-keyword-p`, `lisp-font-lock-syntactic-face-function`),
  plus the level-2 entries that use them.
- `font-lock-syntactic-face-function` and `font-lock-extra-managed-props` in
  `lisp-mode-variables`' `font-lock-defaults`, and the keymap parents
  (`lisp-mode-shared-map` <- `prog-mode-map`) that made `C-M-q`/`M-)` reach
  their commands.
- `font-lock.scm`: the syntactic pass's **comment-delimiter branch**
  (`font-lock.el:1612-1627`), and the alist→buffer-local mapping that had
  made every `font-lock-defaults` entry land under a symbol key the
  renderer never read (`%font-lock-alist-variables`).

## Five engine fixes underneath, four in `search.c`'s territory

1. **`\_<`/`\_>` are assertions now.** The old translation used glibc's word
   boundary, so `&optional` and `:keyword` never matched (`Ssymbol`, not
   `Sword`). The ERE gets an empty group and the search checks the syntax
   table after the match, retrying from the next position.
2. **One Emacs group may be several glibc groups** (`\(?1:` in two
   alternatives): the mapping holds a list. Found as font-lock's "No match
   %s in highlight" on `easy-mmode.el`.
3. **`internal--syntax-propertize`'s `save-match-data`** is a seam
   (`*internal-syntax-propertize-function*`), because `save-match-data` is
   `search`'s and `syntax` is below it. Without it the mode's propertize
   function clobbers the match data of the match being attempted.
4. **`%char-table-runs` resolves parents**: `char_table_ref_and_range` sees
   only a table's own values, and syntax tables always inherit from the
   standard table.
5. **`characters.scm` gained `standard-syntax-runs`** - Emacs 31.1's own
   answers for every Unicode block's syntax above ASCII (234 runs, script
   emitted). Without it every character above ASCII was `word`.

## Method notes

- **The differential is the tool.** `emacs -Q --batch` on one side,
  this tree on the other, `diff` the face runs. It found the delimiter face,
  the `(last x 2)` bug, the numbered-group mapping and the missing Unicode
  syntax in one afternoon; none of them would have been found by reading.
- **A test that asserts on the thing you waited for is hollow** - and the
  same is true of a face comparison written carelessly: the first oracle
  printed `(1+ pos)` for starts and `next` for ends, and every line looked
  off by one until the oracle was fixed, not the editor.
- `%ere-class-runs-text` **enumerates** code points: glibc reads a bracket
  range in collation order, and `[\x7f-\xa0]`/`[←-ⱏ]` are "Invalid range
  end". The non-word runs of a syntax table are 2344 characters, so this
  costs 7 ms once per (table . class).

## Still open

- **A class body must not escape anything.** `%ere-class-escape` wrote `^`
  as `\^`, and glibc gives backslash no meaning inside a bracket
  expression, so every class silently gained a backslash member - which
  is what made `check-declare.el` and `cl-print.el` differ. The three
  special characters are *placed* now (`]` first, `^` not first, `-`
  last). With that the differential is 24/24 files exact.
- `lisp-mode-syntax-propertize`'s `|…|` rule, `elisp-fontify-symbols`, the
  `syntax-propertize-rules` macro, and `cl-indent.el`/`scheme-indent-function`
  are still not ported (unchanged from the indentation pass).

# Closing the colourising pass's departures (2026-11-16)

The four items the previous handoff named, worked in order of size.

## `\<`, `\>`, `\b`, `\B` are assertions now

They were glibc's word boundary; Emacs's are `Sword` tests of the syntax
table, and scheme-mode's *font-lock* table makes `-` a word constituent
- which is exactly why `define-library` painted `define` as a keyword
and `-library` as a function name. That was the "scheme-mode departure"
and it was the same bug as `\_<`.

## `syntax-propertize-rules`: engine in `search.scm`

Ported as a **procedure** (no expansion-time `eval` in Scheme): rule
REGEXPs are strings, actions are thunks or `(prog1 STRING THUNK...)`.
The C's offset accounting, group-0 wrapping, group/backref shifting and
match-data shift are ported. `elisp-mode-syntax-propertize` is Emacs's
four rules again; `lisp-mode-syntax-propertize` is new.

Two traps worth remembering: **`offset` must be `set!`-ed**, not rebound
in the `let*` (or every rule after the first uses 0 and numbered groups
collide with the wrappers); and **`match-data` elides non-matching
trailing registers**, so a shift must tolerate a short list.

`subregexp-context-p` and `regexp-opt-depth` moved into `search.scm`
with it - `(schemacs core regexp-opt)` imports `search` (for `regexp-quote`),
so it cannot be imported back.

## `scheme-indent-function`, its table, and `scheme-syntax-propertize`

The indentation is `scheme.el:562-760` whole, including the
MIT-dialect block (default on) and the nine `scheme-doc-string-elt`
properties. `lisp-doc-string-elt-property` became per-buffer, as Emacs's
`defvar-local` is.

`scheme-syntax-propertize` needed narrowing, which this tree does not
have; the port checks where `forward-sexp` landed instead. Driving it
found a genuine scanner bug: `%forw-comment` used `set!` **in value
position**, where Scheme answers the unspecified value - a nested `#|`
comment made the nesting count `#<unspecified>`.

**A stray `set!` in value position is the same class as `when` in value
position**; both are listed in the earlier handoffs and both cost an
afternoon.

## Verification

- All suites pass (55 now, with `scheme-tests.scm` new).
- Face-run differential: 24/24 elisp files exact.
- Scheme indent differential over the tree's own `.scm` files: exact
  except where Emacs's `indent-region` disagrees with its own
  `calculate-lisp-indent`, plus a nested-`#;` marker case.
- `tools/pty-check.py` to be run.

## Still open (and their true size)

- `common-lisp-indent-function` / `cl-indent.el`: **882 lines**, ~300
  algorithm and ~600 of `put` data.
- `elisp-fontify-symbols` / `elisp-scope.el`: **2,868 lines**; off by
  default (`elisp-fontify-semantically` = nil).

# The Common Lisp indentation engine, and the parse-state cache that was
# never flushed (2026-11-16)

Chris: *"fix those departures"* - the last four named at the end of the
colouring pass. Two were done in the previous commit (`syntax-propertize-rules`,
`scheme-indent-function`); this is the other two, plus the two primitive
bugs that porting them uncovered.

## What landed

- **`schemacs/core/cl-indent.scm`** (NEW) - a port of
  `lisp/emacs-lisp/cl-indent.el`: `common-lisp-indent-function` and the
  loop special case, `common-lisp-indent-function-1`'s walk up the
  containing forms, the `lisp-indent-259` specform engine, the
  lambda-list aligner, `lisp-indent-tagbody`, `lisp-indent-do`,
  `lisp-indent-defmethod`, `lisp-indent-function-lambda-hack`, the 11
  defcustoms, and the whole method table (`defun`, `case`, `cond`,
  `flet`, `tagbody`, `defstruct`, ...; `loop` is not in the table - it
  has its own special case in `common-lisp-indent-function`, as in the
  C). `lisp-mode` installs it as
  `lisp-indent-function`, which is `lisp-mode.el:866`.
- **`derived-mode-p` and the parentage it reads** (`subr.el:2984-3160`):
  `derived-mode-all-parents` (with its cache and the follower flush),
  `provided-mode-derived-p`, `derived-mode-p`, `derived-mode-set-parent`,
  `derived-mode-add-parents`, `derived-mode--flush` - in `derived.scm`,
  because `subr` cannot see a buffer and `major-mode` is `buffer.c`'s.
  `merge-ordered-lists` (C3 linearization, `subr.el:2984`) and
  `intern-soft` went into `subr.scm` beside `intern`.
  `define-derived-mode` now `put`s `derived-mode-parent` and normalises a
  `fundamental-mode` parent to nil (`derived.el:186`), so
  `(derived-mode-all-parents 'prog-mode)` is `(prog-mode)` as in Emacs.
- `lisp-indent-local-overrides` is exported from `lisp-mode.scm`; the
  library list, `imports.scm` and `tools/run-suites.py` carry the new
  library.

## The two primitive bugs this uncovered

**1. `syntax-ppss`'s cache was never flushed on a buffer change.** Emacs
installs `syntax-ppss-flush-cache` on `before-change-functions` the first
time a buffer is parsed (`syntax.el:677`) - *and* `syntax-propertize`
installs it again, because that path does not always go through
`syntax-ppss` (`bug#29767`). Neither was here, so a cached parse state
outlived the edit that moved the positions it describes.

Found by `indent-region` over `cl-indent.el`, which has commented-out
blocks: a line that plainly starts with `;` had `comment-search-forward`
answer nil, so `indent-for-comment` *inserted* a second `;` at the end of
the line. The signature that gave it away: **the indentation of that line
depended on where the region started** (start at 1 → column 0, start at
20000 → column 40, start at 6000 → 40 again). A stale cache is the only
thing that behaves that way.

Two things to remember from fixing it:

- the test is `(unless (or (pair? ppss-cache) ppss-last) ...)`; the C's
  `(unless (or ppss-cache ppss-last) ...)` written directly is **always
  false**, because `'()` is true in Scheme. The hook was not installed
  and nothing said so.
- `syntax.scm` could not call `add-hook` (no import, and `subr` is above
  it), so the list is appended to the parameter directly, with the
  `memq` guard `add-hook` would have done.

**2. `comment-choose-indent` bound `min` and `max` as variables and then
called the procedures of the same name** - legal in Elisp's Lisp-2,
fatal in Scheme's Lisp-1 ("Wrong type to apply: 57"). The locals are
`min-col`/`max-col` now, and the departure is in DEPARTURES.md. Nothing
had ever reached that function: it is only called for a comment *after*
code on the line, and no earlier corpus had one.

## Verified

- `cl-indent-tests.scm` (28): the table's entries (`defun`, `ccase` is
  `case`, the second `if` entry winning, `-for-elisp`), `lisp-indent-find-method`'s
  three arms, `lisp-mode` installing a procedure, and nine
  `calculate-lisp-indent` columns from a fixture that `emacs -Q --batch`
  indents first - `defun` body, `let` binding, `let` body, `defmethod`
  body, `case` clause, `tagbody` tag and form, `let*` binding, `while`
  body - plus a `destructuring-bind` pattern and its body, a backquoted
  list's second element and a `defstruct` slot on a second fixture.
- `lisp-mode-tests.scm` +1 (42): a `.lisp` file opens in `lisp-mode`
  (`auto-mode-alist`'s `("\\.li?sp\\'" . lisp-mode)`), which runs the
  engine's autoload seam for real.
- `derived-tests.scm` +10 (26): the parent chain, `provided-mode-derived-p`,
  the current-mode forms, `derived-mode-set-parent` replacing a parent and
  flushing the cache, and `derived-mode-add-parents`' order - each
  expectation measured on `emacs -Q --batch` first.
- **The differential**: the first forty `lisp/emacs-lisp/*.el` files,
  `lisp-mode` + `indent-region` on both sides, `cmp` the two outputs.
  Against an Emacs with `function-get`'s autoloads forced - which is what
  `emacs-lisp-mode` reads through - **32 identical, 8 different**, and
  every difference is a macro whose property Emacs has only after the
  library defining it is loaded (`ad-do-advised-functions`,
  `iter-defun`, ...). Proven, not assumed: supplying
  `(put 'ad-do-advised-functions 'lisp-indent-function 1)` to this tree
  makes `advice.el` **byte-identical**, so the engine is not the
  difference. Against a *plain* `emacs -Q --batch` the same forty give
  **13 identical, 27 different**, because `common-lisp-indent-function`
  reads the property with a plain `get` and so sees only what is loaded.
  The engine is right; the static table is right for `emacs-lisp-mode`
  and "too complete" for `lisp-mode`, and DEPARTURES.md says why.

- **All 56 suites pass** (`cl-indent-tests` 28, `derived-tests` 26,
  `lisp-mode-tests` 42, `tty-editor-tests` 309, `pgtk-tests` 110).

**A trap in the compile recipe**: `for f in schemacs/**/*.scm` in a
non-interactive bash expands `**` as a *single* `*` unless `shopt -s
globstar` is on - so it compiles `schemacs/editor/*.scm` and silently
skips `schemacs/ui/tty/` and `schemacs/external/`, which are two levels
deep. Found by checking the cache for `.go` files older than their
sources: 39 were missing. Use `find schemacs -name '*.scm'` (or set
globstar) before a battery run.

**Method note that cost an hour**: four probes "proved" `looking-at` was
broken at a position where it was fine, because `(goto-char (- p 1))`
after `search-forward` lands at the *end of the match*, not its start.
Every conclusion drawn from those probes was about a `;` that was not
there. `(goto-char (match-beginning 0))` is the fix, and the lesson is
the file's oldest one: read the shape of the evidence before believing
the conclusion.


# The tab line, part 1: the display primitive (2026-11-16)

Chris asked for `tab-line-mode` and chose the full port of `tab-line.el`.
The blocker turned out to be that **this tree had no header line and no tab
line at all** - `matrix.scm`'s own note said the `tab_line_p`/
`header_line_p` flags were never carried - so the redisplay half had to
come first. This is that half, plus the icon library `tab-line.el` builds
its buttons with. The Lisp half (`tab-line.scm`) is **not written yet**.

## What landed

- **Window parameters** (`window.c`): `window-parameter`,
  `set-window-parameter`, and the `parameters` field on `<window>`
  (`w->window_parameters`). A parameter set to nil is stored, as the C's
  `Fassq`/`Fsetcdr` does.
- **`window_wants_tab_line`** (`window.c:6101`), `window-tab-line-height`
  (`window.c:1233`), and `window-body-top` - the frame row a window's text
  starts on. `window-body-height` now subtracts the tab line.
- **The row is reserved in the redisplay**: `display-window!` starts its
  row walk at `window-body-top`, `blank-glyph-row!`, `cursor-screen-position`
  and `window-to-frame-pixel-y` follow it, and the cursor's pixel walk
  subtracts `window-body-top` rather than `window-top`.
- **`render-window-tab-line!`**: `format-mode-line` on the window's
  `tab-line-format` (the window parameter first, the buffer's variable
  second - `xdisp.c:28182`), drawn with `draw-mode-line!` under
  `tab-line-active`/`tab-line-inactive`. **`draw-mode-line!` was already
  the whole of it** - it draws runs of `face` text properties, `:box`
  included - so a tab's face and box come from the string
  `tab-line-format` builds. It has the mode line's compare-and-skip, on a
  new `last-tab-line` field.
- **The faces**: `tab-line`, `tab-line-active`, `tab-line-inactive`
  (`faces.el:3018`) and the nine `tab-line-tab-*`/`tab-line-highlight`
  faces (`tab-line.el:67-154`).
- **`schemacs/core/icons.scm`** (`lisp/emacs-lisp/icons.el`):
  `define-icon` (a macro that evaluates its specification once, as the
  C's `,specification` does), `icons--register`, the spec merge,
  `icon-string`, `icon-elements`. **Images are not carried** - this tree
  has no image display - so `icons--create` answers #f for `image` and
  `emoji` and the preference falls to `symbol`/`text`, which is what
  Emacs does on a text terminal. `keywordp` moved into `data.scm`, where
  `data.c` has it.

Verified by a geometry probe: a window with no `tab-line-format` has body
height 21 and body top 1; setting the buffer's `tab-line-format` makes
`window-wants-tab-line` true, the height 1, the body 20 and the body top 2.

## What is left, in the order it has to be done

1. **`schemacs/tab-line.scm`**, the Lisp half of `tab-line.el`
   (1,461 lines): the tab-list functions (`tab-line-tabs-fixed-window-buffers`
   is the default, and `window-prev-buffers` is already here), the format
   template with its cache, the auto-hscroll (needs `vertical-motion`,
   `get-pos-property` and `next-single-property-change`, all present),
   the commands, `tab-line-mode` and `global-tab-line-mode`.
2. **`define-globalized-minor-mode`** (`easy-mmode.el`), which
   `global-tab-line-mode` is built with - `font-core.scm` already records
   its absence.
3. **`buffer-match-p`** (`subr.el`), for `tab-line-exclude-buffers`.
4. **`mode-line-window-selected-p`** (`xdisp.c`), the face picker.
5. **The mouse path**: a `tab-line` area in `posn-at-x-y`, and the
   `keymap` text property on the string at the click - which is how a tab
   is clicked at all (`make_lispy_event`). Neither exists yet: the posn
   area list is `'mode-line` and nothing consults a string's `keymap`
   property.
6. **Named, not carried**: `touch-screen-track-tap` (no touch input),
   `popup-menu` context menus (the Gtk front end has a popup; the terminal
   has a menu), `project-current`/`project-name` for
   `tab-line-tabs-buffer-group-by-project`, and `mouse-buffer-menu-mode-groups`
   (`menu-bar.el`) which is only the *default* group table.

**The pty battery run on 2026-11-16 00:32 was against a half-changed tree**
(the record changed under it) and gave 69/86 with `(tab-line-active)`
irritants; it says nothing about either state and must be re-run on a
settled tree.

# The tab line, part 2: the Lisp half, and the primitives under it
# (2026-11-16)

Chris chose the full port of `tab-line.el`. Part 1 was the display
primitive (the reserved row and the drawing); this is `tab-line.scm`
itself - the format the redisplay reads, the tab list, the commands,
`tab-line-mode` and `global-tab-line-mode` - plus the five primitives
each of them needed. **Everything below compiles warning-free, and all
of the tree's suites pass.**

## What landed

| Emacs | here |
|---|---|
| `easy-mmode.el:148` `define-minor-mode`'s `:global` | `easy-mmode.scm` - the PLACE is `default-value`/`set-default` |
| `easy-mmode.el:447` `define-globalized-minor-mode` | `easy-mmode.scm`, new |
| `data.c:2198` `default-value`, `:2213` `set-default`, `:2232` `default-boundp` | `data.scm`, new |
| `bindings.el:872` `mode-line-window-selected-p` | `xdisp.scm`, new |
| `textprop.c:1345` `add-face-text-property` | `textprop.scm`, new |
| `subr.el:2015` `posn-string` | `subr.scm`, new |
| `seq.el` - uniq, difference, sort, sort-by, position, keep, subseq, take, drop, group-by, do-indexed, copy | `seq.scm` (lists only) |
| `fns.c` `copy-sequence`'s list and vector arms | `fns.scm` |
| `tab-line.el` (1,461 lines) | `tab-line.scm`, new |

Tests: `easy-mmode-tests.scm` (29, five groups) and
`tab-line-tests.scm` (23, five groups), both in `tools/run-suites.py`.
`tools/gen-imports.scm` regenerated (85 libraries, 2776 names).

## The five primitives that had never had a caller

All five were written in earlier passes and never exercised; the tab
line is the first thing that calls any of them. Each failed in a
different way, and DEPARTURES.md has the C for each:

1. **`define-icon`'s keyword plist was unquoted** - `(list (quote
   keyword) value ...)` put `:help-echo` in expression position, so any
   icon with two keywords was "Unbound variable: :help-echo". A single
   *string* value worked because strings self-evaluate.
2. **`copy-sequence` had only the string arm** and refused a list, so
   `icons--copy-spec` - `(map #'copy-sequence spec)` - failed for every
   icon before `icon-string` could choose a form.
3. **`icon-string` tested `(null? (and type-spec ...))`** - Elisp's nil
   is `'()` and #f both; `(and ...)` here is #f and `(null? #f)` is
   false, so an absent `symbol`/`text` section fell into `(car #f)`.
4. **`get-pos-property` had no string arm** - the C returns
   `Fget_text_property` for a non-buffer object; ours fell through to
   `buffer-beg` and died. `tab-line--get-tab-property` asks it about the
   tab string.
5. **`posn-string` did not exist**, and it is how a click on a display
   string names its string.

## Two shapes to remember when porting more of `easy-mmode.el`

- **A `:global` mode's variable is `default-value`'s**, not a buffer
  slot. The three data.c functions are in `data.scm`, keyed by symbol in
  a hash table, and `default-value` takes an optional default where
  Emacs signals `void-variable`.
- **A macro that generates a `defcustom` cannot**: a minor mode's
  variable is a buffer-local slot here and a `define-custom` variable is
  a parameter. `:group`, `:version`, `:set`, `:initialize` and `:type`
  are accepted and dropped - see the library comment.

## A macro that emits another macro

`define-globalized-minor-mode` expands to a `define-minor-mode` form.
Two things make that work in this tree and both are worth copying:

- **The nested form's head is spliced from this library's binding** -
  a quasisyntax template's literal `define-minor-mode` resolves here,
  not at the call site, so the caller does not have to import it.
- **The generated names are spliced with the call site's lexical
  context** (`datum->syntax #'global-mode ...`), because they are
  definitions in the caller's library. Everything else written
  literally resolves in `easy-mmode`, which is what keeps a caller from
  importing `add-hook` and `buffer-list`.

**A quoted form in a template cannot hold an unsyntax** - `'#,x` is
`(quote (unsyntax x))`. Build it as `(datum->syntax id (list 'quote
datum))`, which is what `define-minor-mode` already did and what
`tab-line.scm`'s `quoted` helper does.

## Things the tab line taught that outlive it

- **`run-hooks` takes the *list*, not the parameter**: `(run-hooks
  (*hook*))`. Passing the parameter passes a *procedure*, and
  `run-hooks` calls a procedure it is handed - so the hook silently
  returns its list and nothing runs. This cost a probe.
- **`(when TEST BODY)` as a value is not Elisp's nil** - it is the
  unspecified value, which is true and which `append` splices in. Any
  place a `when`'s or an `if`'s result is a list needs `'()`.
- **`(null? #f)` is false.** `(if (null? (and a b)) ...)` is not
  `(if (null x) ...)` over Elisp's nil.
- **A parameter is a procedure**, so `(procedure? *tab-line-tabs-function*)`
  is true for the parameter itself. A defcustom *holding* a procedure is
  read `(*name*)` and then called.
- **A keymap here holds procedures**, so a `defvar-keymap` goes *after*
  the commands it binds. `tab-line.scm`'s order is functions first,
  tables second, and the header says why.
- **`concat` preserves text properties** (it is `fns.c`'s, not
  `string-append`), which is what makes the tab string's `keymap` and
  `tab` properties survive the separator being prepended.

## The region under a theme: it is drawn, and Vantablack's is subtle on purpose

Chasing "marking an area for copy seems broken in the gtk messages
buffer": the region *is* drawn. `C-SPC C-f C-f` in `*Messages*` leaves
`(region-active-p)` true and the highlight on screen - checked with
`pgtk-write-screenshot!` on a live editor under broadway, both with no
theme and with Vantablack loaded.

With Vantablack the highlight is `#1a1a1a` on `#000000`, which is
almost invisible - and it is **the theme's own choice**, not this
tree's: `omarchy.el/themes/vantablack-theme.el` maps
`(bg-region bg-active)` with `bg-active` `#1a1a1a`, and its header
explains that the palette is "pure #000000 canvas" with `selection` as
the only step up. Real Emacs with the same theme shows the same.

So a region that cannot be seen is one of three things, in this order:
the theme's palette (above), a theme load that *failed* part-way and
left the face reset (`face-spec-recalc` runs per face, so a spec that
raises leaves the faces before it themed and the rest not - the
`(tab-line-tab (#f))` bug, fixed), or `transient-mark-mode` off, which
is off only if something turned it off.

## The click dispatch: a tab is a button now (2026-11-16)

Chris chose this as the next step after the tab line landed. Two pieces
of GNU Emacs were missing and are now ported.

### 1. The fake prefix (`keyboard.c:11947`)

"Clicks in non-text areas get prefixed by the symbol in their
CHAR-ADDRESS field." `read_key_sequence` turns one event into two -
`keybuf[t] = posn; keybuf[t+1] = key` - and looks the *pair* up, which
is how `[tab-line down-mouse-1]` is a key at all. `dispatch-key-event`
does the same: when a mouse event's position has a symbol area, it
dispatches the area symbol first and the click second. The area symbol's
own step is *silent* - an unbound area is the ordinary case, and Emacs's
"last event alone" rule then runs the click by itself, which is what the
fail arm already did.

### 2. The position's keymap (`keymap.c:1649`)

`current_active_maps (Qt, position)` takes the `keymap` *text property*
of the string a click landed on and conses it in front of the buffer's
map and the minor modes'. `lookup-keymaps` takes an optional position
now and does the same, reading the property through
`*get-text-property-function*` - `textprop.scm` is *above* `keyboard.scm`
(`buffer.scm` imports keyboard), so the seam is the only way in.

## Three bugs the click turned up, each of which had to be fixed first

1. **`format-mode-line` dropped every text property.** `expand-mode-line-string`
   expanded `%`-constructs by `display`ing character by character into a
   string port. The mode line never noticed, because its own strings are
   plain - but the tab line's strings carry `keymap`, `face` and `tab`,
   so the renderer rebuilt them bare and `(get-text-property 3 'keymap
   drawn-string)` was #f even though the string it was built *from* had
   it. The literal runs are `mode-line-substring`s now (properties
   copied, as the C's `substring` does) and only the *constructed* text
   arrives without them. A `%%` keeps the property of the `%` it came
   from, so a tab named `50%` is still clickable.
2. **`draw-mode-line!` could not draw an anonymous face.** `tab-line.el`
   builds its face modifiers as `(:inherit (tab-line-tab-special FACE))`
   - a plist, which Emacs's `face-attribute` accepts. Ours went to
   `internal-get-lisp-face-attribute` and said "Invalid face". The run's
   attributes are merged with `merge-face-ref` now (which knows a name, a
   plist and a list of either), `face->attribute` uses it for anything
   that is not a symbol, and the `:box` test reads the merged vector.
3. **Every window showed the selected window's tab line.**
   `display_mode_lines` (`xdisp.c:29099`) *rebinds* `selected_window` to
   the window whose line it is about to format, and `old_selected_window`
   keeps the real one. This tree did not, so `tab-line-format` - which is
   written in terms of `(selected-window)` throughout - described the
   wrong window in every split. `frame.scm` has
   `*selected-window-override*` and `*old-selected-window*` now,
   `(selected-window)` answers the override when it is bound, and both
   the mode line and the tab line are formatted inside that binding.
   `mode-line-window-selected-p` is therefore the C's own comparison,
   `(eq? (selected-window) (*old-selected-window*))`, rather than the
   stand-in it had to be before.

## Still to do on the tab line

0. **The scroll arrows work, and `vertical-motion` measures the current
   buffer now.** `tab-line-auto-hscroll` decides whether the tabs fit by
   `(> (vertical-motion 1) 0)` measured in a scratch buffer no window
   shows, and our `vertical-motion` read its text from
   `(window-buffer window)` while taking the width from the same window -
   so it measured the *shown* buffer's lines and answered "the tabs
   wrapped" for every tab line. The C does the other thing: the iterator
   takes width, wrapping and hscroll from `w` and characters from
   `current_buffer`. `buffer-line-texts-at`, `window-line-slices-at`,
   `%window-line-slices`, `window-truncates-lines?` and
   `%row-of-position` take an optional buffer now (the window's, by
   default) and `vertical-motion` passes the current one - falling back
   to the window's when there is none, which a test can produce and a
   live editor cannot. Measured: `(tab-line-auto-hscroll (list
   (make-string 200 #a)) #f)` is `(#t #f)` where it was `(#f #f)`, and a
   tab line whose tabs fit no longer shows a stray `>` button.

1. **The mouse path is done** - see "The click dispatch" above.
   `posn-at-x-y` answers the `tab-line` area with the string drawn
   there, `dispatch-key-event` makes Emacs's two events of it, and
   `lookup-keymaps` takes the string's `keymap` property. Verified on a
   live gtk editor under broadway: clicking a tab ran
   `tab-line-select-tab` and the window switched.

   Not carried: a tab string's `local-map` property (`current_active_maps`
   reads both; nothing here writes one), and the `read-key-sequence`
   buffer switch to the clicked window's buffer before a click's lookup -
   `lookup-keymaps` reads the *current* buffer's map, so a click in a
   window showing another buffer looks that buffer's keys up in the
   current buffer's map. A tab click does not care (its map comes from
   the string), and a mode-line click only reaches `mouse-drag-region`.
2. **`tools/pty-check.py`** has not been run on this tree.
3. Named, not carried (all in `tab-line.scm`'s header): the buffer menu
   behind `tab-line-new-tab-choice`'s `t`, the two context menus,
   touch, `project.el` grouping, `mouse-buffer-menu-mode-groups`,
   `tab-line-tab-name-truncated-buffer` (`truncate-string-to-width`),
   `window-persistent-parameters` and `repeat-mode`.
4. **`global-font-lock-mode` is onto the macro now**, which was the
   hand-written copy this file complained about; `font-core.scm`'s
   `(let ((*inhibit-quit* #t)) ...)` was a `let` over a parameter's name
   and rebound nothing - it is `parameterize` with Emacs's nil.

# Window configurations, and the tab bar (2026-11-16)

`tab-bar.el` has been asked for since the tab line landed, and it stands
on one thing this tree did not have: **`current-window-configuration` and
`set-window-configuration`**. A tab is a named persistent window
configuration, so those two came first, bottom up.

## Window configurations - `window.c` in `(schemacs window)`

`<window-configuration>` holds what the C's `struct save_window_data`
holds - the frame, the flat vector of saved windows, the frame's selected
window, the current buffer, the selected frame - and each `<saved-window>`
holds what `struct saved_window` does: **the window object itself**, its
buffer, point and start as *copies* of the markers, its geometry, its
hscroll state, its persistent window parameters, and its parent's and
previous sibling's **indices into the vector** (`wset_temslot`).

Because the vector holds the objects, restoring a configuration puts back
windows that were deleted since - the C's own "Kludge Alert! Mark all
windows now on frame as `deleted`. Restoring the new configuration
`undeletes` any that are in it" - and their buffer history, which travels
in the object.

Three things had to be copied rather than guessed, and all three are the
C's:

- **`old_point`.** "An exception is made for point in the current buffer:
  its value is -not- saved" is implemented by the C's three-way choice,
  and then by writing `old_point` into the recorded window's `pointm`
  *before* `select_window` hands that marker to the buffer. Leaving the
  write-back out made `C-x 1` followed by a restore jump to the point the
  configuration had recorded, which is exactly what the exception exists
  to prevent.
- **The stride.** `TAB_BAR_ITEM_NSLOTS` is **6**, not the menu bar's 5.
- **`window-restore-killed-buffer-windows`**, whose default nil "will try
  to delete the window if and only if it is dedicated to its buffer" -
  and no window here is dedicated, so a killed buffer's window is kept
  and shows another buffer.

`buffer-live-p` was **wrong** and this work is what found it: it was a
walk of `*buffer-list*`, where Emacs's `BUFFER_LIVE_P` is "has a name"
(`!NILP (BVAR (b, name))`). A buffer made by `allocate-buffer` - which is
what every test and the startup frame are built on - is live and named
and *not* in the list, so every restore took the "buffer is dead" branch.

## The tab bar

| Emacs | here |
|---|---|
| `FRAME_TAB_BAR_LINES` (`frame.h`) | `%frame-tab-bar-lines` (`frame.scm`) |
| `tab_bar_items` (`keyboard.c:9751`) | `tab-bar-items` (`keyboard.scm`) |
| `parse_tab_bar_item` (`keyboard.c:9876`) | `parse-tab-bar-item` (`keyboard.scm`) |
| `update_tab_bar` (`xdisp.c:14291`), `display_tab_bar` (`:14696`) | `update-tab-bar`, `display-tab-bar` (`xdisp.scm`) |
| `tab-bar.el` (1,461 lines of Lisp half) | `tab-bar.scm` (new) |
| `faces.el`'s `tab-bar` and `tab-bar.el`'s six faces | `faces.scm` |

**The layout is the C's**: the tab bar's row is *below* the menu bar's
(`display_tab_bar` starts its iterator at `FRAME_MENU_BAR_LINES`,
`xdisp.c:14717`), and `frame-top-margin` is both counts.

**`parse_tab_bar_item` is not `parse_menu_item`**, and that is the bug
that took the longest: a tab's item carries a *nil binding* - the click
finds its tab by the item's KEY - and `parse_menu_item` refuses a nil
definition in a menu bar. Reusing it dropped every tab but the current
one, and the bar showed one tab and a "+". The C has a second parser for
exactly this reason, and it is ported.

**The `:filter` is applied by `tab-bar-items`.** Emacs binds `[tab-bar]`
to `(menu-item "tab bar" MAP :filter tab-bar-make-keymap)`, and
`get_keyelt`'s `menu_item_eval_property` arm calls the filter at each
lookup. That evaluator is `keyboard.c`'s and `keymap.scm` is below it, so
`tab-bar-items` calls `tab-bar-make-keymap` itself before it walks the
maps - the filter's work, one level up.

## What is not carried, and what each waits for

Each is in `tab-bar.scm`'s header with the same list, which is the
accounting this file asks for rather than a "faithful subset":

- the tab's **window state** (`ws` is nil; `window-state-get`/`put` are
  not ported). Live tabs use `wc`, which is the branch Emacs takes for
  tabs of the same session.
- **tab groups** (`tab-bar-tab-group-*`, `tab-bar-format-tabs-groups`).
- **`tab-bar-history-mode`** and its back/forward buttons: it records a
  configuration before every command, which needs `pre-command-hook`
  bookkeeping the tab line does not have.
- **`tab-bar-auto-width`**: a `display` space specification measured in
  pixels, where this renderer draws cells. The variable is carried so a
  user setting it sees no error.
- **touch, drag and detach** (`tab-bar-mouse-move-tab`,
  `tab-bar-detach-tab` needs a frame built from a configuration).
- `tab-bar-format-align-right`/`-global`, `tab-bar-menu-bar`,
  `tab-bar-rename-tab-by-name`, `frameset-*` persistence.
- **The Gtk tab bar is not drawn**: `display-tab-bar` is the terminal's
  row, as `display-menu-bar` is. A Gtk frame's tab bar would be a widget,
  as its menu bar is.

## The Lisp-1 traps this pass hit, all four of them

1. **A parameter that shadows the procedure it needs**:
   `(define (props props ...) ... (props (cddr props) ...))` applied the
   *list*. That is `parse-tab-bar-item`'s `walk-props`, renamed.
2. **A parameter named `list`**: `(let loop ((rest list) ...) ... (list
   value))` calls the sequence. `tab-bar--insert-at` takes `lst`.
3. **Two names, one meaning**: Emacs has a variable *and* a function
   called `tab-bar-separator`; the second `define` replaced the first and
   `(tab-bar-separator)` applied `#f`. The variable is
   `tab-bar-separator-string` here, as `mule-util.scm` spells
   `truncate-string-ellipsis-string`.
4. **`run-hook-with-args` takes the list, not the parameter** - six call
   sites passed `*tab-bar-tab-...-functions*` and the hook called the
   *parameter* with the hook's arguments.

## Tests

- `window-config-tests.scm` (9): the layout, the selected window, per
  window points (measured against Emacs 31.1, which answers `(1 2)` where
  the obvious expectation is `(3 2)` - the selected window shows the
  buffer that was current when the configuration was recorded), starts,
  an undeleted window, `window-configuration-p`, a killed buffer, and
  `dont-set-frame`.
- `tab-bar-tests.scm` (15): the mode and its frame parameter, the one
  starting tab, new/select/close/rename/close-other, the sole-tab error,
  the format's items, the six-slot parse, a real click through
  `posn-at-x-y` + `tab-bar-mouse-down-1`, and the text area moving down a
  row.
- `tools/pty-check.py` gained **`tab-bar`**, which drives `C-x t 2` and
  `C-x b` on a terminal and reads the bar's row.

## Tab history and tab groups (2026-11-16, second pass)

The two remaining `tab-bar.el` subsystems, ported after the first one
landed.

### `tab-bar-history-mode`

The whole of `tab-bar.el:2566`: `tab-bar-history-limit` (a `defvar`, not a
defcustom - so a plain variable, as in Emacs), the three hash tables, the
pre-change and change functions, `tab-bar-history-back`/`-forward`, and
the mode with its `pre-command-hook`. `C-c <left>` and `C-c <right>` bind
the two commands, and `tab-bar-format-history` now produces its back and
forward buttons - it returned `'()` while the mode was unported.

**One departure, and it is the interesting part.** Emacs notices that a
command changed the window configuration through the frame's
`change_stamp`, which exactly four functions bump - `Fset_window_buffer`,
`Fdelete_window`, `Fsplit_window_internal`, `Fset_window_configuration`
(`window.c:3715`, `:5681`, `:5828`, `:8082`) - and
`run_window_change_functions` runs `window-configuration-change-hook`
when that flag, the selected window or the selected frame moved. This tree
has neither the stamp nor the hook, so
`tab-bar--window-fingerprint` captures what those four events change -
the selected window and each window with its buffer and rectangle - and
the comparison happens at the next command's `pre-command-hook`. The same
events move it and nothing else does; only the moment of the push
differs, and no reader can see that, because `tab-bar-history-back` runs
its own pre-command first. DEPARTURES.md has the C.

Measured: `(current-window-configuration)` is **3 µs** on a two-window
frame, so the per-command snapshot costs nothing beside a keystroke. It
runs only while the mode is on.

### Tab groups

`tab-bar-tab-group-default`, the group format and face functions,
`tab-bar--format-tab-group`, `tab-bar-format-tabs-groups`,
`tab-bar-change-tab-group` (`C-x t G`) and `tab-bar-close-group-tabs`.
The grouped format shows one label per group and only the current group's
tabs; `tab-bar-show-inactive-group-tabs` shows the rest, which was
defaulting to nil in both Emacsen.

Two bugs of the port, both the same shape as ones this file already has:

- **The loop must thread `previous-group`.** Emacs's `(prog1 ... (setq
  previous-group tab-group))` is easy to write as a loop that forgets to
  - and then *every* tab of a group gets a label, which is what the test
  caught on its first run.
- **`tab-bar-history-back` is a variable *and* a command**, like
  `tab-bar-separator` before it; the command definition overwrote the
  hash table and the first `hashq-ref` applied a procedure. The tables
  are `tab-bar-history-back-table`/`-forward-table`.

Tests: `tab-bar-tests.scm` 15 -> 22 (history mode adds the hook, a split
is recorded and undone, forward redoes it, the buttons appear only with
the mode on; group assignment, clearing, and the grouped format).

### The rest of the tab commands (2026-11-16, third pass)

`tab-bar-duplicate-tab`, `tab-bar-move-tab-backward`,
`tab-bar-switch-to-tab` (`C-x t RET`), `tab-bar-close-tab-by-name`,
`tab-bar-rename-tab-by-name` and `tab-bar-move-tab-to-group`, with the
aliases `tab-duplicate` and `tab-switch`, and `C-x t n` bound to
duplicate.

**Correction (2026-11-16).** This paragraph used to list
`tab-close-by-name`, `tab-rename-by-name` and `tab-move-backward` among
the aliases. They are not Emacs's - `tab-bar.el`'s alias list
(`:3179`) has neither them nor `tab-select-tab-by-name`, and the whole
`lisp/` tree has no such names - so they were this tree's inventions,
and they are gone. Emacs's list is now `define-alias`'d in full, and
`tab-list` (which the list *did* have, aliasing `tab-switcher`) with it.

**`tab-bar-move-tab-to-group` is the default value of
`tab-bar-tab-post-change-group-functions`**, which the group pass had
left as `'()` - so grouping a tab now *moves* it next to its group, as
Emacs's does. That changes the order the tests see, and three of them
were written for the old order; they now say why.

### The tab bar on a Gtk frame (2026-11-16, fourth pass)

The tab bar now draws on **both** front ends. **Correction (2026-11-19,
measured in the C): GNU Emacs's Gtk build has no tab-bar widget either.**
`gtkutil.c`/`xmenu.c` build the *menu* bar's widget and contain no
tab-bar code; the redisplay draws the tab bar into `f->tab_bar_window`
below the menu bar (`pgtkterm.c` reads `FRAME_TAB_BAR_LINES` and
hit-tests that window), exactly as on a terminal. The paragraph here
used to say Emacs "gives it a widget above the drawing area
(`xg_create_frame_widgets`)" and call our first-row-of-the-text-area
drawing a departure; both halves were wrong, and that false note is
what produced the "implement the gtk tabs" suggestion. What actually
differs is the window *object*: a click's `posn-window` here is the
frame, where Emacs answers its `tab_bar_window`.

Three small changes made it work, and each was a bug on its own:

- `frame-top-margin` returned 0 for a window-system frame (the menu bar
  is a widget there, so *its* rows are 0) - it now counts
  `tab-bar-lines` on both, since the tab bar has no widget.
- `update-tab-bar`/`display-tab-bar` had a `window-system` guard left
  over from the menu bar's shape; it is gone.
- **`display-tab-bar` placed the row at `%frame-menu-bar-lines`**, whose
  default is 1 - so on Gtk the bar drew at row 1, *on top of the first
  text row*, and the cursor landed on the tab bar. The row is now
  `(- (frame-top-margin frame) (%frame-tab-bar-lines frame))`, which is
  the menu bar's rows on a terminal and 0 on a toolkit frame. The same
  expression is now what `posn-at-x-y` uses to tell a `menu-bar` area
  from a `tab-bar` one.

Verified live under broadway: the bar draws `bar-test.txt x  +` on the
first row, the buffer's text starts on the next, the cursor is in the
text, and `(tab-bar-mouse-down-1 ...)` with a `posn-at-x-y` position
switches tabs. **A running editor keeps the old code** - the first
screenshot after the fix still showed the old layout because the editor
had not been restarted.

### The right-aligned item, and the tab list (2026-11-16, fifth pass)

**`tab-bar-format-align-right` and `tab-bar-format-global`** are ports at
last, with the piece of redisplay they stand on: a `display` property of
`(space :align-to N)` on a caption is honoured by `display-tab-bar` -
`tab-bar-format-align-right` leaves a marker that `tab-bar-format-list`
replaces with one such item, exactly the C's `align-right-p`/`rest`
variables. `frame-inner-width` is the target (`frame.c`'s function, and in
this tree a column count, which is what `FRAME_PIXEL_WIDTH` is on a
terminal), and `*global-mode-string*` is new in `xdisp.scm` beside
`*mode-line-format*` - a parameter, empty until a mode fills it, which is
Emacs before `display-time-mode` is on.

**Two bugs of the port, both about the space spec.** `(string-append)`
with no arguments is an error in this Guile (Elisp's `mapconcat` over nil
answers ""), and the spec **replaces the character it sits on** - drawing
the space *and* the padding put the next item one column past the frame
edge, which the screenshot showed as a clock with its last digit cut off.

**`tab-switcher`** (`M-x tab-switcher`, the `*Tabs*` list) is the whole of
`tab-bar.el:2700`: the centred read-only list of the *other* tabs sorted
by recency, `d`/`x`/`RET`/`u`/`DEL`/`SPC`/`n`/`p`/`q`, and the delete and
select commands. Not carried: `:suppress t` (typing a letter in the list
inserts it) and `?` (`describe-mode` does not exist) - the same gap
`special-mode-map` names.

`tab-bar-closed-tabs` became **a parameter** here: `tab-switcher-select`
`let`-binds it to nil around the close, and that is the test the
convention gives.

Tests: `tab-bar-tests.scm` 24 -> 28 (the align-right item and its target,
the empty global string, the list's contents and read-only flag, and
selecting from it); `tools/pty-check.py`'s `tab-bar` config now sets a
fixed clock through `*global-mode-string*` and asserts it sits at the
right edge of the bar's row. Verified live on Gtk under broadway:
`12:34` flush with the right edge of the drawing area.

### The Menu button (2026-11-16, sixth pass)

`tab-bar-format-menu-bar` and its `tab-bar-menu-bar` command, with
`menu-bar-keymap` underneath in `menu-bar.scm` - `menu-bar.el:2899`, the
bar's own items as a keymap with `menu-bar-final-items` sorted last.
That one had to be written for a *record*-based keymap: Emacs builds
`(keymap ITEM...)` as a list, and here the map is a record filled with
`define-key`, which prepends - so the items go in back to front (final
items first in reverse order, then the rest reversed) to come out in the
C's order. Its `(lookup-key (menu-bar-current-active-maps) [menu-bar])`
is this tree's `lookup-keymaps` walked for the first map whose
`[menu-bar]` is a keymap, which is now exported from `keyboard.scm`.

Also a variable-read trap: `*menu-bar-final-items*` is a **plain
variable** in this tree (it carries the `(set! *x* *x*)` self-assignment
against the compiler's constant folding), so `(*menu-bar-final-items*)`
applied the list - "Wrong type to apply: (help-menu)".

The button pops the bar through `popup-menu`, which the menu-bar work
already exercises; the *popup itself* is not driven by any test, and the
terminal's is only reachable through a real click on the bar's Menu item.

# Window states, and the size engine under them (2026-11-16)

`tab-bar.el`'s last named gap is closed: a tab carries the frame's window
state, `'clone`/`'window` new-tab choices rebuild a layout from one, and a
tab from a saved session can be restored with `window-state-put`.

## What landed

| Emacs | here |
|---|---|
| `window.c`: `window-pixel-*`, `window-total-*`, `window-size`, `window-normal-size`, `window-new-*`, `window-resize-apply(-total)`, `window-combination-limit`, `window-dedicated-p`, `window-fringes`, `window-margins`, `window-scroll-bars`, `window-vscroll`, `window-child`/`-right`/`-left`/`-last-child` | `frame.scm` - a new "window tree's algebra" section at the end of the file |
| `window.el:379-2100`: `window-normalize-window`, `window-min-size`, `window-sizable`, `window-size-fixed-p`, `window-min-delta`/`max-delta`, `window--resizable`, `window-resizable` | `window.scm` |
| `window.el:2721-3400`: `window--size-to-pixel`, `window--pixel-to-total`, `window--resize-reset`, `window--resize-this-window`, `window--resize-siblings`, `window--resize-child-windows`, `window-resize`, `window-resize-no-error` | `window.scm` |
| `window.el:6370-6920`: `window-state-get`, `window--state-get-1`, `window--state-put-1/2`, `window-state-put`, `window-state-buffers` | `window.scm` |
| `window.el` `window-deletable-p`, `split-window-no-error`, `walk-window-subtree`, `window--check` | `window.scm` |
| `tab-bar.el:1690` `(cons 'ws (window-state-get))`; `:1771` the `ws` restore branch; `:2077` `'clone`/`'window` | `tab-bar.scm` |

`window-start` moved from `indentc.scm` to `frame.scm`, where `w->start`
lives; `indentc.scm` imports it. `window-live-p` moved from `window.scm`
to `frame.scm` and is now the C's test (`WINDOW_LIVE_P` = a window with a
buffer) rather than "is on the frame's window list", which answered false
for the minibuffer window while no prompt was up.

DEPARTURES.md has the representation choices: the size registers live in
`*window-slots*` beside the window (as `w->cursor_off_p` already does),
pixel sizes are derived from the row/column rectangles, normal sizes are
derived rather than stored, and the decoration queries answer a
terminal's answers on both front ends.

## The four bugs the tests found, all of the same shape

1. **A `(when ...)` whose body had been swallowed by its own condition.**
   `window-state-put`'s size check closed one paren too early, so the
   whole rest of the function was inside the `when`, and with `totals`
   true (the ordinary case) the function returned the *unspecified*
   value and did nothing. Symptom: `window-state-put` returned
   `#<unspecified>` and the layout was untouched. The tell was a
   depth-profile of the form (a Python scanner that skips strings and
   comments): the body sat one level deeper than the `let` that should
   have contained it. **A compensating close elsewhere keeps the file
   balanced**, so the reader, the compiler and the suite's other tests
   all pass - only this function misbehaves.
2. **`(prog1 (split-window ...) (delete-window window))` written the
   other way round**: `(set! window new) (delete-window window)` deletes
   the *new* window and leaves the state being put into a window that is
   no longer on the frame. The restore then silently did nothing.
3. **`*window-restore-killed-buffer-windows*` applied as a procedure.**
   `(procedure? *parameter*)` is true - the parameter itself is a
   procedure - so the branch ran and then applied the *parameter* object
   with three arguments: "Wrong number of arguments ... () | (x)". The
   same class as `run-hooks` taking the list: a parameter must be called.
4. **`(cdr #f)` where Elisp's `(cdr nil)` is nil** - a state with no
   `combination-limit`, `next-buffers` or `prev-buffers` entry. Every
   lookup now goes through `window--state-ref`, which answers `#f`.
5. **A local variable named `list` shadowed the procedure.** Emacs's
   `window--state-get-1` binds `(let ((parameters ...) list) ...)` and
   builds its answer with a backquote; the port wrote
   `(list (cons 'parameters list))`, which applied the accumulator as
   soon as a window carried any parameter at all. The accumulator is
   `acc` here and the source says why.
6. **`get-buffer` answered nil for a buffer.** The docstring's second
   sentence - "If BUFFER-OR-NAME is a buffer instead of a string, return
   it as is" - is the C's `BUFFERP` arm, and it was missing, so a
   window state (which names its buffers *as buffers* when it is not
   writable) found nothing and `window-state-put` restored every window
   with the wrong buffer. Fixed at the primitive (`buffer.scm`), which
   is where the rule lives.

## The state's shape, and the `assq` it needs

A state is `(HEAD . SUBTREE)`, where HEAD is the twelve `min-*` pairs and
SUBTREE is the root node: the type symbol consed onto the alist, then the
children. Emacs's `assq` finds the *root's* entries because the C
compares `XCAR (XCAR (tail))` and the root's entries are elements of the
top-level spine - but it does **not** find anything inside a
`(buffer ...)` sublist, and `(assq 'dedicated STATE)` is nil in Emacs
too. `window--state-assq` reproduces that exactly (with the pair test
the C's `XCAR` gives a non-cons silently). Two consequences worth
knowing before writing a test:

* an entry of a *node* is found by `(window--state-ref KEY NODE)`;
* an entry of the *buffer section* needs
  `(window--state-ref 'dedicated (window--state-ref 'buffer NODE))`;
* `window-state-buffers` answers the same buffer **twice** for a
  one-window state in Emacs - the root's entry and the node's are the
  same one - and this port matches.

## The numbers, measured

Every expectation in `window-state-tests.scm` (35 assertions) came from
`emacs -Q --batch` on the same tree: a leaf's `window-min-size` is 4/2/1
tall and 10/2/2 wide for IGNORE nil/t/safe; a vertical combination's is
the sum (8) and an ortho-combination's the maximum; `10/14 +3 -> 13/11`,
then `-5 -> 8/16`; `(window-resizable r 100)` is the sibling's room above
its minimum; `window-resize-no-error` past that answers nil.

The tree's text area is 23 rows where Emacs's batch frame is 24 (its echo
area is a window and takes the last row), so the tests assert the *rule*
where the number depends on the frame, as the recentring tests do.

## Still not carried

* `tab-bar-split-tab`/`tab-bar-merge-tabs` (they need
  `window-get-split-combination`), `tab-bar-move-tab-to-frame`, the
  touch/drag tab commands - all `window-state-*` clients that were named
  before this pass.
* `window--sides-check`/`window--atom-check` (no side or atomic windows).
* `window-preserve-size` (the parameter is read by `window--preserve-size`
  and written by nothing here).
* `get-mru-window`, and so the "minibuffer was selected" step of
  `tab-bar-select-tab-internal`.
* `window-state-put`'s `window-state-put-kept-windows` callback is called
  with Emacs's four arguments when `window-restore-killed-buffer-windows`
  is a procedure; nothing in this tree sets one.

## A suite with several groups needs a `test-end` for each

`srfi 64` prints its summary - "Test suite finished" and "# of expected
passes" - only when the group stack empties. `window-state-tests.scm` has
six `test-begin`s and was written with a single `test-end` at the end: the
tests all passed and the runner still said **DID NOT RUN**, because it
counts the summary line and there was none. Every `test-begin` now has
its `test-end`. (The runner's own note explains the other half of this
check: a suite that dies inside its *second* group also used to read
green.)

## Verified

All 62 suites pass (window-state-tests 43, tab-bar-tests 32 - the two
new ones are the `clone` layout and the recorded `ws`), the tree compiles
with no new warnings, and the tab bar still restores a tab's layout.

# Splitting a tab, and the window-tree rule under it (2026-11-16)

`tab-bar-split-tab` and `tab-bar-merge-tabs` were the last named gap in
the tab bar, and they needed what `window-x.el` builds on. Doing it
bottom-up turned up **a departure in `split-window` that everything
above it had been shaped around**: this tree made a new parent on every
split, where the C reuses the parent whenever the window is already in a
combination of the same direction. The picture on the screen was the
same; the *tree* was not, and the tree is what `window-child-count`,
`window-state-get`, `other-window`'s order and `tab-bar-split-tab`'s ARG
read.

## What landed

| Emacs | here |
|---|---|
| `window.c:5427` `Fsplit_window_internal`'s `combination_limit` | `%split-window-install!` in `window.scm` |
| `window.c:5443` the reference window | `split-window`'s `refer`: the frame's selected window when OLD is internal |
| `window.c:5213` `combine-windows` | `combine-windows`, beside `split-window` |
| `window.c:5691` `delete-window-internal` | `delete-window-internal` |
| `window.c:2612` `recombine_windows` | `recombine-windows` |
| `window.el:4318` `delete-window` | `delete-window`, over the resize engine that was already here |
| `window.el:586`/`:614` `walk-window-tree-1`/`walk-window-tree` | same names in `window.scm`; `walk-window-subtree` is now the sub-only call Emacs makes it |
| `window.el:325` `window-child-count`, `:914` `window-main-window` | same names |
| `window-x.el:417` `window-get-split-combination` | **new library** `(schemacs window-x)` |
| `tab-bar.el:1965`/`:1978`/`:2014` | `tab-bar-move-window-to-tab`, `tab-bar-split-tab`, `tab-bar-merge-tabs`, plus the `split-tab`/`merge-tabs` aliases |

Two variables changed kind: `*window-combination-limit*` (new, default
`window-size`, a `window.c` DEFVAR) and `*window-combination-resize*`
(was a plain `window-combination-resize`). Both are parameters because
Emacs `let`-binds them around code that reads them several frames down -
a Scheme `let` would be invisible there. `window-combined-p` grew its
optional arguments for `window--state-put-1`'s call. `window-absorb!`
is gone with the old `delete-window`.

## Splitting an internal window: the completion list went 12/11 -> 18/5

`split-window` on an *internal* window is what `display-buffer-at-bottom`
does - `(split-window-no-error (window-main-window))` - and this tree's
completion list splits the frame's root every time it opens. The
rectangle arithmetic alone is wrong for one: the C's
`split-window-internal` ends with `window_resize_apply (p, horflag)`, and
the Elisp wrapper shrinks the old window's children through
`window--resize-this-window` *before* the split, so an internal window's
children give up the new window's share **in proportion**. Ours set only
the old window's own rectangle, leaving its children at their old sizes -
and the delete, which is Emacs's now, handed the rows back in
proportion, so a frame that was 12/11 before `C-x 2` then `TAB`
collapsed to 18/5 when the list was closed. `pty-check.py`'s
`completion-resize` is the check that caught it.

`%split-window-install!` now does the redistribution when the split
window is internal (reset, `set-window-new-pixel`, `window--resize-this-window`,
`%window-resize-apply-1` - the C's *static* apply, which frame.scm
exports for this). `split-main-window-below` is a thin call to
`split-window` with a **negative** size: `split-window`'s positive SIZE
is the *upper* window's rows, and the helper's SIZE is the new window's.

The lesson generalises to the whole pass: **the tree's two size models
have to agree at a seam**. `absorb-into!` (used by the old
`split-main-window-below`) shrinks only the child touching the edge,
which stays consistent only if every neighbour does the same; the
resize engine distributes by normal size. Once `delete-window` was on
the engine, the two disagreed and the frame changed shape under the user.

## The four bugs, all in the new code, all the same shape as before

1. **`(frame-selected-window window)`** where the frame was meant: a
   record accessor on the wrong record, which surfaced as a `struct-vtable`
   error from a printer three frames away.
2. **The combination's axis read after the unlink.** `delete-window-internal`
   asks `window-left-child parent` to decide vertical from horizontal;
   with one child left, `windows-stacked?` needs two and the answer
   flips to horizontal, so `window-resize-apply` applied the wrong axis
   and returned `#f` - the window kept its old rectangle and the frame
   never filled. The C reads it before unlinking (`window.c:5717`); so
   does this now.
3. **`split-window` on an internal window copied `(window-buffer window)`**,
   which is `#f`, into the new leaf - and `set_frame_buffer`-less code
   died later. `tab-bar-merge-tabs` splits `(window-main-window)`, which
   *is* internal whenever the tab has more than one window. The C's
   reference-window rule is the fix.
4. **A test that called `window-get-split-combination` twice on one
   frame.** It combines - it rewrites the tree - so the second call saw
   two children instead of three and answered the wrong side. Emacs is
   the same; the test now gives each call its own frame.

## Method notes

- **A compiled procedure's source line is where to look, not the frame
  name.** `(frame-procedure-name)` was `#f` for every interesting frame
  and `(frame-source)` pointed into `ice-9/eval.scm`; what named the
  culprit was printing the *arguments* the condition carried and seeing
  a symbol where a record should be. Guile's record printers and
  accessors make "expecting struct: X" mean "an accessor got X".
- **`(car 'leaf)` is an error, `(cdr #f)` is an error.** Two of the
  probes in this pass died in their own printing code, not in the
  editor, and each time the backtrace pointed at the editor because
  that was where the frame beneath it was. Read the top frames first:
  if they are `(guile-user)` procedures, the bug is in the probe.
- **`window--opt` is the tree's `&optional`**, and `window-combined-p`
  had been written with two required arguments where Emacs's has one
  optional; the compiler's "possibly wrong number of arguments" warning
  is what caught the call site that needed it.

## Still not carried

- `split-frame`, `merge-frames`, `window-make-frame` - they need a
  `make-frame` that can be handed a window configuration; `window-state-put`
  into a new frame's root is the shape, and nothing asks for it yet.
- `tab-bar-detach-tab` and `tab-bar-move-tab-to-frame` (a frame per tab),
  `tab-bar-split-tab`'s cousins in `window-x.el`.
- The side-window and atomic-window handling in `split-window`,
  `delete-window` and `window-get-split-combination`: the parameters are
  read, and nothing here sets `window-side`, so the branches are dead
  but harmless.
- `delete-window-choose-selected`, `get-mru-window`, and
  `window-parameter`'s `delete-window` function.

## Verified

All 62 suites pass (`window-state-tests` 65, `tab-bar-tests` 38,
`tty-editor-tests` 309), the tree compiles with no new warnings, and
`tools/pty-check.py` is **88/88** on the tree as committed. (An earlier
run of the same tree gave 87/88, the one failure being `completion-ui` -
on the battery's documented flake list, C-g straight after TAB being a
between-key race - and it passes **3/3 when run alone**. The check this
pass *did* break, `completion-resize`, is described above and passes.)

Two method notes on the way out:

- **A check that fails only in the battery, and passes alone, may still
  be yours.** `completion-resize` failed alone as well, which is what
  separated it from the flake; run a suspect alone *twice* before
  filing it under "load".
- **`(car 'leaf)` and `(cdr #f)` are errors**, and two probes in this
  pass died in their own printing code with the backtrace pointing at
  the editor because that was the frame underneath. Read the top frames
  first: if they are `(guile-user)` procedures, the bug is in the probe.

# The `*` interactive code, and `comment-indent` as a command (2026-11-16)

Chris: *"if emacs calls it defalias, maybe we should call it
define-alias?"* - the alias work landed in `7fdaff6`, and this is the
follow-up it opened: `newcomment.scm` ports
`(defalias 'indent-for-comment #'comment-indent)` but neither was a
command, because `comment-indent`'s `(interactive "*")` uses a code this
tree did not read.

## What landed

- **`interactive-proc` reads `*`** (`callint.c:98`, peeled with the other
  leading markers at `:362`): the check runs, then the rest of the
  specification is read as it would have been. `"*"` alone leaves the
  empty specification, so the entry is a thunk; `"*P"` leaves the
  prefix-taking one. `^` was already read this way; the other three
  markers (`+`, `-`, `@`) are Emacs's own special cases and are not
  carried.
- **`*barf-if-buffer-read-only-function*`** in `command.scm` - a seam,
  because `barf-if-buffer-read-only` is `buffer.c`'s and `buffer.scm`
  cannot import `command.scm`. **`keyboard.scm` installs it** as it
  loads, beside its own use of the same function. Read at call time, not
  at definition time.
- **`comment-indent` is a `define-command`** with `(interactive "*")`
  and a **rest parameter** for the C's `&optional continue` - the
  procedure is called with no argument from `indent-for-comment` and
  from Lisp modes, and a required parameter would have made every one of
  those calls an arity error.
- **`indent-for-comment` is `(define-alias indent-for-comment
  comment-indent)`**, which is `newcomment.el:75`'s `defalias` - so
  `M-x` finds both names.

`command-tests.scm` (new, 10 tests) drives the *interactive entry* on the
command's record - exactly what the command loop calls for a keypress -
because that is the only way to test the check: a direct call to the
command bypasses the specification entirely. It pins the seam being
installed, `"*"` running on a writable buffer and signalling `"Buffer is
read-only"` on a read-only one *before the body runs*, `"*P"` still
getting the prefix, `"*^P"` stacking both markers, the empty
specification's thunk, and `define-alias`'s shared record.

## The traps in this one

- **The record's `spec` field is not the interactive entry.** `new-command`
  files the entry in `procedure` and the `uarg` flag in `spec`; a test
  that asks `command-interactive-spec` for the entry gets `'uarg` and
  wonders why it is not a procedure. Use `command-procedure`.
- **The entry for the empty specification takes zero arguments**, while
  every other entry takes `uarg` - and the record's flag says "takes
  one" for any non-#f specification. So a marker wrapper has to decide
  its call shape from *what remains of the string*, not from the marker.
  The first version called `(base uarg)` unconditionally and a `"*"`
  command died with "Wrong number of arguments".
- **A probe that imports `command` but not `keyboard` sees the seam
  unset** and reports the check missing when it is the probe that is
  incomplete. `(procedure? (*barf-if-buffer-read-only-function*))` in
  the suite is the guard against that.

# The interactive codes are a loop now, and the region codes are in (2026-11-16)

The follow-on to the `*` marker. `interactive-proc` compared the whole
specification with `string=?` against one code at a time, so
`"r\nP"` - `indent-region`'s own spec - could not be written, and every
region command spelled its spec as an expression.

## What landed

- **`%interactive-args`**: `callint.c`'s loop over the code characters.
  `p`, `P`, `e`, `i`, `r`, `R`; `\n` and `-` separate codes and
  contribute nothing; an unread code errors naming the character.
- **`%interactive-markers`**: the leading markers (`*`, `^`, `-`, `+`,
  `@`) peeled before any code is read (`callint.c:362`). `*` is the
  read-only check from the previous pass, now one of a family rather
  than a special case; `+` errors; `^` and `@` are recognised and do
  nothing (no shift-select, no mouse-event window).
- **Four seams** - `*check-mark-function*`, `*region-beginning-function*`,
  `*region-end-function*`, `*use-region-p-function*` - installed by
  `simple.scm`, which is the library that has all four.
- **`check-mark`** (`callint.c:156`) lives in `simple.scm` for want of
  its state, and answers the mark's position.
- Commands back on their Emacs specs: `kill-region`, `upcase-region`,
  `downcase-region` (`"r"`), `eval-region` (`"r"`, rest parameter for
  the nil PRINTFLAG), `indent-region` (`"r\nP"`).
- `command-tests.scm` 10 -> 21: `r` both ways round and sorted, `R`
  nil when the region is inactive, both mark errors *in `check_mark`'s
  order*, `i`, `-`, `+`, and `"r\nP"`'s three arguments in order.

## The thing to know about this pass

**`check_mark` and `region_limit` ask the same two questions in the
opposite order** - `callint.c:156` tests "is the mark set" first,
`editfns.c:232` tests "is it active" first. A tree that implemented `r`
as `(region-beginning)` + `(region-end)` gets every ordinary case right
and one message wrong. That is exactly the class of departure that
reading the C catches and testing does not, so `check_mark` is ported
whole and the test pins the corner (no mark set, transient mode on).

## The `d` and `m` codes, and the invalid-code message (2026-11-16)

The two interactive codes that read nothing and were still missing:
`d` ("Value of point. Does not do I/O", `callint.c:502`) and `m`
("Value of mark", `:623`). Both hand the command a **marker**.

- `m` is exact: `check_mark (false)` - the message is "The mark is not
  set now", not the region's - and then the buffer's *own* mark marker,
  so moving the argument moves the mark. `command-tests` pins the
  identity with `eq?`.
- `d` is `(point-marker)`, where the C repositions a **static,
  bufferless** marker (`Fmake_marker` + `set_marker_both (…, Qnil, …)`).
  Same position; `marker-buffer` differs, and a bufferless marker would
  not move with edits. DEPARTURES.md has the three answers that differ.
- Two new seams, `*point-marker-function*` and `*mark-marker-function*`,
  installed at the bottom of `editfns.scm` - the library that has both.
  **A missing install is an error naming the function** here
  (`%interactive-seam`), not a silent `#f`, because `d` has no value
  that `#f` could mean.
- The **invalid-code message is the C's**: ``Invalid control letter `q'
  (#o161, #x0071) in interactive calling string``, with the C's
  zero-padding done by a local helper rather than a format directive
  (this tree's errors carry a template *and* irritants).

`command-tests.scm` 21 -> 30: the two seams installed, `d`'s marker at
point and not following point afterwards, `m` returning the buffer's
own mark marker, `m`'s no-mark message, and the invalid-letter text.

**Correction to the previous handoff's list**: there is no `l` code.
`callint.c`'s switch has 30 letters and a `+`; the earlier list here
carried an `l` that does not exist in Emacs 31.

All 63 suites pass and `tools/pty-check.py` is 89/89 on this tree.

**A warning about that battery, because it cost an hour here.** The
first full run on this tree failed `quit-after-prefix` and then died in
`back-door` with a `subprocess.TimeoutExpired` - and the obvious reading
was a regression. It was not: `back-door` alone then passed 5/5, and the
*baseline* (`e139a83`, stashed and recompiled to test it) passed too.
`back-door` is the check whose own note already says the client "may
connect before the editor has torn that session down"; it is a
one-session-at-a-time race, and the two failures were it. **Stash,
recompile, run the check on the baseline before believing a red
battery** - and note that `git stash` rewrites every source's mtime, so
the cache has to be warmed again or the baseline is compiled against
the wrong code and lies.

### What is left of `callint.c`

Eighteen codes, and **every one of them reads the minibuffer** - so each
needs a seam in `command.scm` plus an installer in the library that has
the reader, the way the region four need `simple.scm`:

| codes | reader | lives in |
|---|---|---|
| `s` `S` `M` | `read-string` (`minibuf.c:1420`) | `minibuffer.scm` |
| `n` `N` | `read-number` (`subr.el`) | `minibuffer.scm` |
| `b` `B` | `read-buffer` (`minibuf.c:1522`) | `minibuffer.scm` |
| `a` `C` | `completing-read` over the obarray | `minibuffer.scm` |
| `f` `F` `G` `D` | `read-file-name` (`minibuf.c`) | `files.scm` |
| `c` | `read-char` (`keyboard.c`) | `keyboard.scm` |
| `k` `K` (`U` after them) | `read-key-sequence` (`keyboard.c`) | `keyboard.scm` |
| `z` `Z` | `read-coding-system` | `coding.scm`/`mule-cmds.scm` |
| `x` `X` | `read-minibuffer`, `eval-minibuffer` | `minibuffer.scm` |
| `v` | `read-variable` (`cus-edit.c`) | `custom.scm` |

**The two names that collide** and need a decision before they are done:
`*read-buffer-function*` and `*read-file-name-function*` are **Emacs's
own variables** (`read-buffer-function`, `minibuf.c:2544`;
`read-file-name-function`), and both are already in this tree under
those exact names (`minibuf.scm` holds the first). So a seam cannot be
spelled the way `*barf-if-buffer-read-only-function*` is; the `%`
prefix that `%kill-buffer` took, or a different word, is the choice
waiting there.

Worth knowing before doing any of them: **`d`/`m` (`245` and `215` in
`lisp/`) and `n` (`545`) are the most-used codes in Emacs's own
`lisp/`**, and `a` (`347`), `s` (`375`), `f` (`246`) follow - but this
tree's commands mostly use interactive *expressions* for those (Emacs
itself does for `find-file`, `switch-to-buffer` and `kill-buffer`), so
the immediate gain is in ports that quote a `"…"` spec verbatim.

## A specification's prompts, and `s`/`S`/`M`/`n`/`N` (2026-11-16)

Every interactive code that was left is a minibuffer read, and all of
them are **prompted** - so the prompt machinery came first, because it
is what they stand on.

**The prompt is part of the specification string.** `callint.c:441`:
each code owns the text after it up to the next newline, and that text
is the prompt (`visargs[1] = make_string (tem + 1, sz)`). So
`"sSearch: \nrRegion: "` is two codes with two prompts. This tree walked
single characters and treated `\n` as a nothing-separator, so that text
was unreachable. `%interactive-segments` is the C's walk now and answers
(CODE . PROMPT) pairs.

**And the prompt is `format`ted with the arguments already read**
(`callint_message = Fformat_message (i - 1, visargs + 1)`), which is how
`"sQuery replace %s with: "` shows what the earlier `s` read. That
needs `format-message` - `editfns.c`'s, above this library - so
`*format-message-function*` is a third seam, installed by `editfns.scm`.
The C's parallel `visargs` array is a second accumulator, with its
"if visargs[i] is nil and args[i] is a string, use it" applied as each
argument is pushed.

Five codes on top of it: `s`, `M` (both `read-string`; `M`'s
inherit-input-method is not carried - no input method here), `S`
(`read-string` then interned, the *string* being the visible form), `n`
(`read-number`, visible as `number->string`), and `N` (the prefix when
there is one - the C's `goto have_prefix_arg` - else `read-number`).
Two more seams, `*read-string-function*` and `*read-number-function*`,
installed by `minibuffer.scm`.

Measured rather than assumed: **a `%` in the first code's prompt is
"Not enough arguments for format string"** in Emacs 31.1, so the
formatting is unconditional. And **`-` in the middle of a specification
is an error** - the peel loop handles only the *starting* characters and
the switch has no `case '-'` - where the old loop skipped `-` anywhere.

`command-tests.scm` 30 -> 44 with both readers **stubbed**: what is
tested is the machinery (the prompt a code is given, the argument
order, a later prompt formatted by an earlier answer), and
`tty-editor-tests.scm` gains the assertion that a real editor has the
real two - which a stub cannot show.

**Nothing in the tree uses these codes yet.** Every prompted command
here spells its spec as an expression, and so does Emacs for the ones
this tree has. They are carried because a spec quoted from Emacs's own
source is now readable as written.

### `back-door` was aborting the battery, and now it reports

The check's client calls raised `subprocess.TimeoutExpired` out of
`during()`, out of `drive()` and out of `main()` - so **one stuck client
took the whole run down and the checks after it never ran**, reporting
nothing about themselves. That is worse than a red check, and it is what
two of this pass's three battery runs did.

Both halves are fixed in `tools/pty-check.py`:

* a timeout is now a `CompletedProcess` with returncode 124 and no
  output, so a caller decides what it means;
* the first client after the greeting socket gets a **fifteen-second
  first attempt and two retries**, because the door serves one session
  at a time and the greeting's close may not have been noticed yet - the
  race this file has recorded twice. Losing it now costs fifteen seconds
  instead of hanging, and a client that loses it three times is a named
  problem ("the door accepted a client and never greeted it").

Three runs of `back-door` alone: 3/3.

### The `f` `F` `G` `D` codes, and the naming rule for seams

Four more: `f`, `F`, `G` and `D`. **The naming rule is settled**: a seam
takes the plain `<function>-function` name *unless Emacs has a variable
of that name*, in which case it is `interactive-`-prefixed. That is why
`*read-string-function*` and `*read-number-function*` keep the plain
spelling and these two are `*interactive-read-file-name-function*` and
`*interactive-read-directory-name-function*` -
`read-file-name-function` is Emacs's own defcustom.

Three codes are one seam (`f`, `F`, `G` differ only in the constants
`Qlambda`, `Qnil`, `""`, written at the call sites in `command.scm`);
`D` is its own because its DEFAULT and PREDICATE are buffer state and a
function in `files.scm`. **MUSTMATCH is the symbol `lambda`, not `t`** -
`completing-read` binds `minibuffer-completion-confirm` to anything that
is not `t`, so the two are not interchangeable. **`D`'s PREDICATE is not
carried** (`read-file-name` takes none here), so a `D` prompt completes
files as well as directories: a named departure.

`command-tests.scm` 45 -> 51 (stubs record the *whole call*, which is
what pins the constants); `tty-editor-tests` asserts the real two.

### The `b` `B` codes (2026-11-16, same day)

`b` (existing buffer) and `B` (possibly nonexistent) - and both are
"the whole call is the seam", because the C's DEFAULT is buffer state:
`b`'s is the current buffer *unless the selected window is the minibuffer
window*, in which case `other-buffer`; `B`'s is `other-buffer` always.
MUSTMATCH is `Qt` for `b` and `Qnil` for `B` - a **third** spelling
beside `f`'s `Qlambda`, and all three are the C's, with different
observable behaviour.

### The `z` and `Z` codes (2026-11-16, same day)

`z` (a coding system, or nil) always reads; `Z` **reads only with a
prefix** and answers nil without one, touching the minibuffer not at all.
`Z` needed `read-non-nil-coding-system` (`coding.c:8646`) ported - a
`completing-read` loop, RET on empty asks again - into `mule-cmds.scm`
beside `read-coding-system`.

**Worth knowing: a seam is only installed when its library loads.** These
two live in `mule-cmds.scm`, which the editor core does *not* load - the
two front ends do (`ui/tty/tty-main.scm`, `ui/gtk/gtk-main.scm`). Every
other seam is in a library the core always loads. A `z` spec in a session
with neither errors by name, which is the honest report.

That was found by an assertion placed in the wrong suite
(`tty-editor-tests` is not a front end and never imports `mule-cmds`); it
is in `mule-cmds-tests.scm` now.

### The `C` `v` `x` `X` codes, and the obarray problem (2026-11-16)

Four more, and each needed its `minibuf.c`/`simple.el` function ported
first: `read-command`, `read-variable`, `read-minibuffer`,
`eval-minibuffer`, all in `minibuffer.scm` because all four prompt.

**`C` had no obarray problem after all**: `command-completion-table` is
the command table asked the completion-table way, and every name in it is
already a command, so the C's `Qcommandp` predicate has nothing left to
reject.

**`v` did.** `read-variable` completes over `Vobarray` with
`custom-variable-p`, and that predicate only answers *about a symbol you
already have* - it cannot enumerate. So `custom.scm` gained a registry,
`custom-variable-names`, which `custom-declare-variable` pushes onto; that
list is the collection. Same answers as the C's, from a list instead of a
hash table.

`x`/`X` answer the *form* where the C's visible form is the typed string,
so a later prompt's `%s` after an `x` shows nil. Recorded.

`command-tests.scm` 60 -> 66; the installation group covers all four.

### The `c` code, and `read-char` vs Guile's `read-char` (2026-11-16)

`c` needed `read-char` (`keyboard.c:11240`), ported into `keyboard.scm` as
**`read-char-event`** - not `read-char`, which is Guile's (a character
from a *port*, used by `coding.scm`, `theme.scm` and the tests). The
compiler's "non-idempotent binding for `read-char`" is what said so, and
it is the `insert-newline` collision again.

**A seam whose installer names a function *in the same library* must be
installed after that definition.** The first version of this install sat
beside `*barf-if-buffer-read-only-function*` at the top of
`keyboard.scm`, where `read-char-event` does not exist yet - thirty suites
died at load with "Unbound variable: read-char-event", and the suite
runner named them (`DID NOT RUN` plus the backtrace). It is the same rule
`define-key` follows: a binding resolves when the *form* runs, not when
the file is read. Installs of a library's own functions go at the end.

`char_resolve_modifier_mask` is **not carried**: `read-key-event` has
already folded the modifiers, so there is no mask to resolve. What is
left of `read_filtered_event`'s flags is the type test. The echo clear
(`message1_nolog (0)`) is `*message-clear-function*` from `editfns.scm`,
and "Non-character input-event" is raised in `command.scm`, as the C's
caller does.

### What is left of `callint.c`: 4 codes, and all four are blocked

`callint.c` has 30 letters plus `+`; **26 are carried**. The four left are
not seams onto existing readers:

| codes | blocked on |
|---|---|
| `k` `K` `U` | `read-key-sequence` and its vector form - `read_key_sequence` proper: prefix keymaps, echoes, the up-event discard |
| `a` | an **obarray of functions**. `C` got by on the command table; `a` completes over *every* `fboundp` symbol, and Guile has neither an obarray nor a function table to enumerate |

`read-char` is done, which was the gateway the other three key codes
stood behind - `read_key_sequence` is the larger machine on top of it.
That is the honest remaining edge of `callint.c` in this tree.

| codes | reader | lives in | blocker |
|---|---|---|---|
| `a` `C` | `completing-read` over the obarray | `minibuffer.scm` | needs a predicate over `fboundp`/`commandp` |
| `c` | `read-char` | `keyboard.scm` | |
| `k` `K` (`U` after them) | `read-key-sequence` | `keyboard.scm` | |
| `x` `X` | `read-minibuffer`, `eval-minibuffer` | `minibuffer.scm` | `x` must read *without* evaluating |
| `z` `Z` | `read-coding-system` | `coding.scm` | |
| `v` | `read-variable` | `custom.scm` | |

## No obarray, and the one code that looked like it needed one (2026-11-16)

Chris pushed on this until it was settled, so it is written down:

**There is no universal registry here, and none is wanted.** GNU Emacs has
one obarray and *no* command list - `M-x` is `completing-read` over
`obarray` with `(commandp sym)` as the predicate (`simple.el:2400`), and
`read-variable` is the same call with `custom-variable-p`. Emacs derives
each set by filtering everything. This tree inverts it and keeps the
answers: `*command-table*` for commands, `custom-variable-names` for
custom variables, `coding-system-alist` for coding systems, the buffer
list for buffers, the filesystem for files.

**The price of keeping an index, and the one rule it imposes**: a command
is found *by name* only if something filed it. `define-command` files it;
`define-alias` files the second name; a bare `define` of a procedure files
nothing - so a key bound to that procedure works (dispatch finds a command
by its procedure) while `M-x` cannot see it. That asymmetry is exactly
what made `define-alias` necessary.

**`%file-command-name! (name record)` is the one way into the table.**
It was `register-command-alias!` for the alias half, which named an object
the table does not have - filing a command and filing a second name for it
are the same operation, and the table has no notion of "alias" in it any
more than the obarray does. A nil record files nothing, which is
`defalias` of a non-command being a non-command.

### The `k` `K` `U` codes, and a thousand lines that were not needed

`read_key_sequence` (`keyboard.c:11441`-`:12444`) is one function of about
a thousand lines - but they are **the whole input pipeline**, not sequence
assembly: decode/translation maps, the echo of the partial sequence, mouse
prefixes, discarded input. This tree has that pipeline already
(`read-key-event`, `function-key-translate`, and the modal lookup the
command loop runs for a chord), so the port is the assembly only: read an
event, `modal-lookup-state-step!`, loop while the binding is a prefix.

**Sizing a C function before porting it is what made this one cheap.**

Three departures: the down/up discard is not carried (so **`U` always
answers nil** - and no `"U` spec exists in all of `lisp/`), the partial
sequence is not echoed, and `k`'s visible form is nil because
`key-description` lives above `command.scm`.

### `:suppress t`, and the `[remap ...]` path that was dead (2026-11-17)

Chris: "fix the suppress-keymap thing since you say it's a bug".

**`suppress-keymap` is `subr.el:1316`'s and is a remap** -
`[remap self-insert-command] -> undefined`, plus `-` ->
`negative-argument` and digits -> `digit-argument` - not ninety-five
direct bindings, which is what the first attempt did and what the battery
caught. Measured on Emacs 31.1 in a `special-mode` buffer: `?a` ->
`undefined`, `?5` -> `digit-argument`, `?-` -> `negative-argument`.

**The bug underneath was bigger than the feature**: `command-remapping`
guarded `(symbol? command)`, and `remapped-command` hands it
`(command-name record)` - a **string**, because `new-command` takes it
from `symbol->string`. So every `[remap ...]` binding in the tree had
been dead; `command-remapping` interns a string first now.

`undefined` itself is Emacs's `subr.el` command but lives in
`keyboard.scm`, because its message is built from
`this-single-command-keys` (`*this-command-keys*`), which is that
library's.

**A pty check was pinning the departure it replaces**: `eval-expression`
asserted "Buffer is read-only" on typing in `*Backtrace*`; with the remap
the letter never reaches the buffer and Emacs says "z is undefined". The
check is corrected.

### The stale tab gap notes (2026-11-17, same pass)

`tab-bar.scm` listed tab groups, `tab-bar-history-mode` and
`tab-bar-menu-bar` as not carried when all three are in the file;
`tab-line.scm` listed the context menus when they are implemented over
`popup-menu` (`menu-bar.scm`). Both corrected - a gap note that
overstates is as expensive as one that understates.

### The `a` code, carried without completion (2026-11-16)

`a` asks for the name of *any* function, not a command - the ones worth
instrumenting are rarely commands. Emacs gets that from the obarray with
`fboundp`. Here it is **carried without completion**: the name is typed,
and the C's predicate becomes a resolution (`eval` in the user
environment, then `procedure?`), which is the direction that does
anything. Two departures, both reachable only from an `a` spec: no TAB,
and a name that resolves to a non-procedure errors rather than simply not
being offered. The whole call is the seam, installed by
`minibuffer.scm`, as with `b` and `D`.

**All 30 letters and the `+` are now carried.**

### The argument that settled it: why `a` needs no list at all

It reads "the name of a symbol with a function definition" and completes
over `Vobarray` with `fboundp` - *all functions*, since the ones you would
want to instrument or debug are precisely the ones no key is bound to, so
the command list cannot stand in.

But **completion is the only thing that needs enumeration**, and `eval`
(`(eval sym (current-module))`, or `module-ref`) already does the
direction that matters: name to procedure. So if `a` is ever wanted it is
`read-string` -> intern -> `procedure?`, with "no completion collection"
recorded against Emacs's obarray sweep. No registry.

And nothing wants it: Emacs uses `"a"` in **5** interactive specs in all of
`lisp/` - `elp` twice, `edebug`, `timer`, `5x5` - and the first three are
the host's job here (Guile's `statprof` for profiling, Guile's traps and
`,trace` for stepping), `5x5` is a game, and `timer.scm` has no commands
yet. (`cancel-function-timers` would need adapting anyway: Emacs compares
`(timer--function timer)` with the *symbol*, and a timer here holds a
procedure.)

**So the remaining `callint.c` work was `k` `K` `U`, and its cost turned
out to be sequence assembly rather than a registry - see above. With those
in, and `a` follows it with **no list either** - see below.**

# The window change stamp, and the history hook on it (2026-11-17)

Chris: "fix the change_stamp thing". This is `window.c`'s change notice,
ported whole, and it replaces the fingerprint `tab-bar-history-mode` had
been using. DEPARTURES.md has the C each rule was taken from and the full
account of what is not carried; this is what the next session needs.

## What a window change now is

`FRAME_WINDOW_CHANGE` is set by six sites (`window.c:3715`, `:4427`,
`:4896`, `:5681`, `:5828`, `:8082`) and `redisplay_internal` calls
`run_window_change_functions` (`xdisp.c:17588`). That walks the frames
whose flag is set, asks per live window whether it changed buffer, pixel
or body-pixel size, or is new (`w->change_stamp != f->change_stamp`), and
asks whether the frame has fewer windows than at the last run. **Only
then** does `window-configuration-change-hook` run. `tab-bar--history-change`
is on that hook, which is where Emacs has it.

`<frame>` gained `change-stamp`, `window-change`, `old-selected-window`
and `number-of-windows`; `<window>` gained `change-stamp`, `old-buffer`
and the four old sizes. All six `make<window>` sites and the one live
`make<frame>` take the new arguments.

## The thing that was wrong, and how it was wrong

The previous session's note said a `set-window-configuration` restoring
the layout the frame already had pushes a history entry in Emacs and not
here, because the C sets the flag unconditionally. **Measured on Emacs
31.1 in a pty: it does not push.** The flag is the first gate only; the
per-window comparison is what decides. Taking the flag as the answer would
have pushed exactly where Emacs does not - the correction was wrong in the
same direction the departure was.

The general lesson is already in this file twice, and this is a third
instance: **when the claim is about behaviour, measure before writing it
into a note**. The C *looks* like it says the flag is the answer, because
the unconditional set is right there and the per-window walk is a page
further on.

## What to measure with, and where the table is

`emacs -nw` under `script -qec` writing results with `with-temp-file`,
then reading them back - `--batch` does not redisplay, so every hook count
comes out zero and looks like "Emacs never runs the hook". The six-row
table (split 1, no-op restore 0, real restore 1, select-window 0,
set-window-buffer different 1, same 0) is pinned in
`test/window-test.scm`, a new suite.

## Two flag sets that are this tree's, not the C's

`delete-other-windows` (`window.scm`) and `resize-frame-windows!`
(`frame.scm`) assign rectangles directly where the C runs
`window_resize_apply` or sets the flag itself, so each sets it by hand,
marked at the line. Without the second, a resized terminal frame ran no
configuration hook at all.

## Traps this pass

- **The record's field order is the constructor's order.** The first
  attempt passed `#f 0 #f` where the fields were `change-stamp`,
  `window-change`, `old-selected-window` - the comment beside the call
  was in a different order from the record, and `(+ #f 1)` killed the
  hook on its first run.
- **`window.scm`'s block was written in one deeply nested form and its
  parens never came out right.** The way that worked: write the block to
  `/tmp/block.scm`, read it with Guile's reader counting top-level forms,
  and splice it whole. Hand-counting inside a five-deep `let*`/`lambda`
  nest produced "unexpected end of input" three times.
- **The C sets `window_change_record_frames` *before* running the
  configuration hook** (`window.c:4296` then `:4308`), so a hook that
  signals still leaves the record due. With the order reversed, a failing
  hook left the flag set and would have run again on every redisplay.
- **`xdisp -> window` is a diamond, not a cycle.** The earlier attempt
  put the call in the command loop because it believed `window -> xdisp
  -> simple -> window`; `window.scm` does not import `xdisp` at all.
  `redisplay-frames!` is where `redisplay_internal` calls it now.

# `tab-bar-auto-width` (2026-11-17)

The first of the tab-bar/tab-line remainder. `tab-bar-auto-width`
(`tab-bar.el:1288`) is ported, with `string-pixel-width` under it in
`xdisp.scm` (DEPARTURES.md says why it lives there rather than in a
`subr-x` library).

* It is called from `tab-bar-make-keymap-1`, where Emacs calls it
  (`tab-bar.el:1283`), and it **mutates the item's caption** - which is
  safe because every format function conses fresh item lists on each
  call.
* The padding is `(apply propertize " " (text-properties-at 0 name))`, as
  the C has it; a `string-append` of a plain space would lose the face and
  the bar would measure and draw it differently.
* **`tab-bar-auto-width-min` is a `defvar` in Emacs**, so it is a plain
  variable here; `tab-bar-auto-width-max` is a defcustom and so a
  parameter (`(*tab-bar-auto-width-max*)`). Writing one for the other is
  the mistake this cost: `(when *tab-bar-auto-width-max* ...)` compiles
  and tests the *procedure*.
* `tab-bar-tests` gains two: the captions are un-stretched with the
  feature bound off (the item-shape test, which now binds
  `(*tab-bar-auto-width* #f)`), and two tabs of different name lengths
  come out the same width with it on. The second was run with the
  feature bound off and seen to fail (`(#f #f)`).

## What is left in tab-bar after this

`tab-bar-detach-tab`, `tab-bar-move-tab-to-frame`, `tab-bar-mouse-move-tab`
(drag), `tab-bar-mouse-context-menu`, `tab-bar--load-buttons`,
`tab-bar-get-buffer-tab`/`tab-bar--reusable-frames`,
`tab-bar-minibuffer-restore-tab`/`tab-bar-select-restore-windows`, the
`frameset` persistence, the Gtk tab bar as a widget, and touch (no touch
events exist in either front end).

# The tab bar's drag / right-click / detach (2026-11-17)

`tab-bar-mouse-move-tab`, `tab-bar-mouse-context-menu`,
`tab-bar-move-tab-to-frame` and `tab-bar-detach-tab` are in, with the
`<drag-mouse-1>` and `<down-mouse-3>` bindings the C's `tab-bar-map` has.
DEPARTURES.md has the shape; three things are worth carrying forward:

* **`make-frame` now applies its parameter alist** (after creation, via
  `set-frame-parameter`), because detaching needs the new frame to carry
  the tab's name. The creation functions take no arguments here, so this
  is the nearest shape to Emacs's `frame-creation-function` merge.
* **`assoc-delete-all` had a real bug**: its skip loop tested
  `(car (car rest))` without the C's `(consp ...)` guard, so an alist
  whose head is a symbol - a tab is `(tab (name . ...) ...)` - raised.
  Found by `tab-bar-move-tab-to-frame`, which is the first caller to
  hand it one. `subr-tests` pins it.
* **A variable and a command of the same name bit again**:
  `tab-bar-new-tab-to` used `tab-bar-history-back` as a hash table, and
  the command of that name had replaced it. The tables are the `-table`
  names; grep for the bare name when touching that section.

## Still open in tab-bar

`frameset-*` persistence, `tab-bar-select-restore-context`, the Gtk tab
bar as a widget, `tab-bar-get-buffer-tab`, `tab-bar--load-buttons`
(the buttons are the same `text` strings the icon spec falls back to),
and touch (no touch events in either front end).

# Narrowing - `BEGV`/`ZV` on the buffer (2026-11-17)

Chris chose "narrowing first, then all of fill.el", and this is the first
half. DEPARTURES.md has the C and the reasoning; what the next session
needs to know:

* **`buffer-beg`/`buffer-z` answer `BEGV`/`ZV` now.** They always claimed
  to be `point-min`/`point-max` in their docstrings; they were the text's
  `BEG`/`Z`, which is the same thing until something narrows. The whole
  text is `buffer-text-base`/`buffer-text-z` of `(text-editor-text b)`.
  That one change bounds every scanner correctly.
* **A record change**: `<buffer>` gained `begv`/`zv`. `rm -rf
  ~/.cache/guile/ccache` before believing anything - and note the failure
  mode: a *stale* `.go` for `undo.scm` kept writing the old field index,
  so the undo list landed in the `zv` slot and the symptom was
  `(+ #f 1)` two libraries away.
* **`ZV` has to be maintained at every writer**: `insert-from-string-1`,
  `del-range-2`, and *both* `replace-range`/`replace_range_2`, which write
  through `buffer-text-delete!`/`insert!` directly. Missing the replace
  path made an overwrite lose the tail of the line - `(aX  3)` where
  Emacs gives `(aX b 3)`.
* **`delete-region` signals outside the restriction**; it does not clip.
* `save-restriction` is a `syntax-rules` macro over `dynamic-wind` with
  two markers, the end one insertion-type 1.

`editfns-tests.scm` has a `schemacs_editor_editfns_narrowing` group whose
every expectation was measured on Emacs 31.1 first.

## Next: fill.el

The core (`fill-paragraph`, `fill-region-as-paragraph`,
`fill-region-as-paragraph-default`, the adaptive-fill prefix helpers, the
nobreak predicates, `canonically-space-region`, the justification half)
can now be ported whole, including the four functions that narrow
(`justify-current-line`'s full mode, `fill-comment-paragraph`,
`set-justification`, `fill-individual-paragraphs`).

# What narrowing now reaches (2026-11-17, second pass)

Chris: "are there areas of the code that should use narrowing but don't
because it wasn't available before? Search and replace maybe?" Yes - the
tree had a dozen comments reading "there is no narrowing here". This pass
took the ones whose Emacs source is unambiguous; DEPARTURES.md has the C
for each. In one line each:

* **the searches** follow `search_command`'s bound rule now (`search.c:1006`):
  nil BOUND is `ZV`/`BEGV`, an explicit one must be on the right side of
  point and is then clipped to `[BEGV, ZV]`. That is the "search and
  replace" half: a search inside a `save-restriction` stops at it.
* `indent-according-to-mode` widens (unless INHIBIT-WIDEN), as `indent.el`
  does;
* `line-number-at-pos`'s ABSOLUTE picks `BEG` and takes POS as it stands;
  without it POS is clipped to `[BEGV, ZV]`;
* `set-marker-restricted` clips to `BEGV`/`ZV` (`marker.c:564`);
* `goto-line` has the `save-restriction`/`widen-automatically` block;
* `%n` says `" Narrow"`;
* `beginning-of-defun-raw` scans widened with `floor`/`ceiling` clamps;
* `looking-back` GREEDY is ported, and with it two bugs went: its match
  data was relative to a *copy* of the text (so `font-lock`'s
  `(match-beginning 0)` was wrong), and a nil REGEXP was an error where
  the C's `concat` makes it an empty pattern - `(looking-back nil)` is t.

New primitives: `buffer-narrowed-p` (`subr.el`, in `editfns.scm` because
`subr.scm` is below it) and `widen-automatically` (`simple.el:7691`, a
plain variable - nothing `let`-binds it).

**Still waiting on narrowing, named in DEPARTURES.md**: the
syntax-propertize pair (`scheme`/`elisp-mode` narrow around the sexp they
scan), `dired`'s widen, `elisp--preceding-sexp`, `lisp-comment-indent`,
`lisp--el-funcall-position-p`, `simple.el`'s `count-lines`,
`eval-region`'s string read, and `replace-string-in-region` /
`replace-regexp-in-region`.

## The trap in `looking-back` GREEDY

The C's extension stops at the **first** position that does not match
(`subr.el:5936`). Written as "try every start and keep the furthest" the
answer is the same and the walk is the whole buffer - and each step
copied the text from S to `ZV`, so font-lock (which calls this with
GREEDY on every comment end) went quadratic and the editor wedged. The
pty battery caught it as a 90-second REPL timeout inside
`completion-scroll`. The walk is contiguous now, and the copy stops at
PT - which is the C's own `(narrow-to-region (point-min) start)`.

## Narrowing's own clipping rules, all checked (2026-11-17, third pass)

The primitive is complete for everything `BEGV`/`ZV` governs, each rule
read from the C and tabulated in DEPARTURES.md. The one that was still
missing is `buffer-substring`: it had no `validate_region`, so a range
reaching outside a narrowing read past it where Emacs signals "Args out
of range". `delete-region`, `buffer-substring`,
`buffer-substring-no-properties` and `casify-region` all open with the
same `validate_region`, which is `buffer.scm`'s - do not write a second
copy (this pass did, and deleted it).

Not carried, and each is a real Emacs feature rather than a gap in the
port: labeled restrictions (`with-restriction`/`without-restriction`) and
`narrowing-locked`.

What is left is *call sites*, not the primitive: the syntax-propertize
pair, `dired`'s widen, `elisp--preceding-sexp`, `lisp-comment-indent`,
`lisp--el-funcall-position-p`, `simple.el`'s `count-lines`,
`eval-region` and `replace-{string,regexp}-in-region`.

# fill.el, and the four primitives it broke open (2026-11-17)

Chris chose "narrowing first, then all of fill.el". This is that pass:
`schemacs/textmodes/fill.scm` is `lisp/textmodes/fill.el` whole, on top of
the primitives it stands on - and the primitives were most of the work.
DEPARTURES.md has the C and every departure; this is what the next
session needs.

## What landed

`schemacs/textmodes/fill.scm`: `fill-region`, `fill-region-as-paragraph`
and its default, `fill-paragraph` (M-q), `unfill-paragraph`,
`fill-comment-paragraph`, `canonically-space-region`,
`current-fill-column`, the adaptive fill prefix (`fill-context-prefix`,
`fill-match-adaptive-prefix`, `fill-common-string-prefix`), the five
no-break predicates and `fill-nobreak-p`, `fill-delete-prefix`,
`fill-delete-newlines`, `fill-move-to-break-point`, `fill-newline`, the
justification half (`current-justification`, `set-justification` and its
five commands, `justify-current-line`, `unjustify-current-line`,
`unjustify-region`), `fill-individual-paragraphs` and
`fill-nonuniform-paragraphs`, Emacs 31's two semantic-linefeed commands,
`beginning-of-line-text` (`indent.el`'s, moved up) and
`with-buffer-unmodified-if-unchanged` (`subr-x.el`'s, defined here).

Under it, in the files Emacs has them:

| Emacs | here |
|---|---|
| `char-equal` (`editfns.c:4418`) | `editfns.scm` |
| `subst-char-in-region` (`editfns.c:2294`) | `editfns.scm` |
| `insert-before-markers`, `-and-inherit` (`editfns.c:1388`, `:1422`) | `editfns.scm` |
| `fix-position` (`editfns.c:2281`) | `editfns.scm` |
| `buffer-hash` (`fns.c:6454`) | `fns.scm` |
| `string-to-list` (`subr.el:4739`) | `subr.scm` |
| `current-left-margin`, `move-to-left-margin`, `indent-to-left-margin`, `back-to-indentation`, `fill-prefix` | `indent.scm` |
| `paragraph-start`, `paragraph-separate`, `use-hard-newlines`, `sentence-end` + its five variables, the real `forward-paragraph`/`backward-paragraph`, `start-of-paragraph-text`, `end-of-paragraph-text`, the sentence motions | `paragraphs.scm` |
| the `left-margin` buffer-local | `buffer.scm` |

## The method that found everything: fill the same file both ways and diff

Seven fixture texts, filled by `emacs -Q --batch` and by this tree, then
`diff`. That harness is now `fill-tests.scm` - every expectation in it is
the Emacs output byte for byte. It found five bugs that reading had not:

1. **`fill-nobreak-p` returned `'()`**, an empty list, which is *true* in
   Scheme where Elisp's nil is false. Every ordinary space was "do not
   break here", so `fill-move-to-break-point` walked back to the front of
   the paragraph and the fill broke after the first word. The
   `run-hook-with-args-until-success` answer is now converted.
2. **`fill-move-to-break-point`'s backward loop repeated unconditionally**
   where the C's `while` body is the `when`: the search re-found the same
   space for ever. Written as `(when (re-search-backward ...) ... (loop))`
   with the `loop` inside the `if`'s non-rejecting arm.
3. **`fill-individual-paragraphs`' recursion was a sibling of its `when`**
   instead of its body, so the outer loop span for ever at one position.
4. **Markers do not do arithmetic.** `(> to (point))` with `to` a marker
   is a plain type error here; `%pos` reads `marker-position` at each
   comparison. `fix-position` (added to `editfns.scm`) is the same rule
   for `subst-char-in-region`'s arguments.
5. **`\c|` is a character category** and the engine rejects `\c`. Every
   `\c|` search is omitted, with a comment saying why; see DEPARTURES.md.

## Two Emacs behaviours worth knowing

* **`fill-delete-prefix` with a `to` at `point-max` loops for ever in
  real Emacs too** - measured, `emacs -Q --batch` hung on it. It is only
  safe with the marker `fill-region-as-paragraph-default` passes.
* **Elisp's `if` takes several ELSE forms** (`(if COND THEN ELSE...)`).
  Every multi-form arm of the C is a `begin` here.

## Wiring

`fill.scm` binds `M-q` (and `M-g M-q`) on `*default-keymap*` at load, so
both front ends import it - `ttk-main.scm` and `gtk-main.scm` each have
`(only (schemacs textmodes fill))` beside `paragraphs`. `loadup.scm`'s
library list carries it, so `imports.scm` has its names for M-:, the REPL
and the init file; regenerate with `tools/gen-imports.scm`.

`tools/run-suites.py` runs `fill-tests.scm`.

## The clash census caught two of this pass's own duplicates

`loadup-tests.scm`'s "no exported name is two different bindings" failed
on the first full run: `back-to-indentation` and `*page-delimiter*` were
each defined twice - once where they already lived and once in this
pass's new code. Both are Emacs's in the *other* file, and that is the
fix in each case:

* `back-to-indentation` is `simple.el`'s, but `indent.el`'s
  `current-left-margin` calls it and `indent.scm` is below `simple.scm`.
  It moved **down** into `indent.scm` (with `skip-syntax-forward` and
  `backward-prefix-chars` along with it), and `simple.scm` imports and
  re-exports it - the same move `beginning-of-line` made into `cmds.scm`.
* `page-delimiter` is `paragraphs.el:213`'s defcustom and `page.el` only
  reads it. It moved **up** into `paragraphs.scm` from `pages.scm`, which
  now imports and re-exports it.

`indent-region`'s first branch - "If a fill-prefix is specified, use it"
- is ported as well now that `*fill-prefix*` lives in `indent.scm`.

## `M-q` is two commands in Emacs 31

Measured: in a **fundamental-mode** buffer `(key-binding "\M-q")` is
`fill-paragraph`; in a **prog-mode** buffer it is
`prog-fill-reindent-defun` (`prog-mode.el:106`), which fills the comment
or string at point and otherwise reindents the defun. This tree binds M-q
to `fill-paragraph` on the global map, which is Emacs's answer for the
modes it has. `prog-fill-reindent-defun` belongs in `prog-mode.scm`'s map
when that map is consulted; `fill-region` and `unfill-paragraph` are
M-x-only in Emacs, and the `M-g M-q` this pass briefly bound was invented
and is gone.

## The narrowing call-site audit, closed (2026-11-17)

The list DEPARTURES.md carried ("still waiting on narrowing") is worked
through. Three were real and are ported - `dired-readin`'s `widen`,
`scheme-syntax-propertize-sexp-comment`'s narrow-to-END (which is what
turns "the sexp runs past END" into the `scan-error` the C catches), and
`up-list-default-function`'s `no-syntax-crossing` arm, verified against
Emacs on four cases including one inside a string and one inside a
comment. **Three were not narrowing issues at all** -
`elisp--preceding-sexp`, `lisp-comment-indent` and
`lisp--el-funcall-position-p` do not narrow in Emacs either; the audit
note that named them was a guess, and correcting it matters as much as
the work (a gap note that overstates stops the next person asking).
`replace-string-in-region`/`replace-regexp-in-region` are blocked on
`replace-buffer-contents` (`insdel.c`), which is not ported - they are
not a narrowing job.

## Auto Fill mode, and the bug it found (2026-11-17)

`auto-fill-mode`, `do-auto-fill`, `internal-auto-fill`,
`default-indent-new-line` and the `auto-fill-function` buffer slot are
in, with `internal_self_insert`'s call to them. Verified by typing the
same text one character at a time in both editors at `fill-column` 20:
identical output. Two placements are forced by the import graph and
named in DEPARTURES.md: the auto-fill half of `simple.el` lives in
`fill.scm` (`simple` is below `paragraphs`, which `fill` imports), and
`auto-fill-chars` lives in `cmds.scm` (a char-table in `character.scm`
would close a cycle through `chartab -> intervals -> buffer ->
buffer-text -> character`).

**The first test run caught a real bug three files away**:
`fill-comment-paragraph` had dropped the C's `(fill-prefix fill-prefix)`
binding, so filling a comment wrote the comment's `;; ` into the
*parameter*, and the next buffer's auto-fill continued its lines with
it. `parameterize` now, and the auto-fill tests are the regression test.

## Still to do

* `comment-indent-new-line` (the comment-continuation half of
  `newcomment.el`) - it is `comment-line-break-function`'s default, and
  without it auto-fill inside a comment does not repeat the `;;`. It
  needs `comment-beginning`, `comment-valid-prefix-p`, `comment-forward`,
  `comment-enter-backward` and `comment-styles`.
* A typed RET does not auto-fill: `insert-newline` inlines the insert
  where Emacs's `newline` calls `self-insert-command`. Fixing it means
  routing `insert-newline` through `internal-self-insert`, which also
  brings `post-self-insert-hook`.
* `replace-buffer-contents` (`insdel.c`), which
  `replace-string-in-region`/`replace-regexp-in-region` wait on.

## `define-minor-mode`'s ARG, and the names its form reads (2026-11-17)

Found by asking a generated command what it does rather than by any test
- and all three answers were departures.

**A bare `(auto-fill-mode)` raised "Wrong number of arguments".** Emacs
generates `(defun ,mode (&optional arg ...))`; this macro generated a
required parameter. And a bare call **enables rather than toggles** -
measured on Emacs 31.1: nil is not `'toggle`, so it takes the `(t ...)`
arm; `(auto-fill-mode)` twice leaves it on, `(auto-fill-mode nil)`
enables, and only the *interactive* form's `'toggle` toggles. The
command is `(define-command (#,mode-id . rest)` with ARG from REST now.
DEPARTURES.md has the Emacs table.

**The generated interactive form names two things the calling library
must import.** It is Emacs's
`(list (if current-prefix-arg (prefix-numeric-value current-prefix-arg)
'toggle))`, evaluated in the command's *defining* module. `font-core`,
`face-remap` and `fill` did not import `current-prefix-arg` or
`uarg->integer`, so **`M-x font-lock-mode`, `M-x text-scale-mode` and
`M-x auto-fill-mode` raised "Unbound variable: current-prefix-arg"** and
the command loop's guard made them keys that did nothing. This is the
missing-import class again, and the tell is the same one as before: the
command works when called as a procedure and fails when a key reaches
it, because only then is the specification evaluated. All three import
both names now, and the macro's comment says why. `easy-mmode-tests.scm`
drives the interactive *entry* - `((command-procedure (command-record-of
CMD)) #f)` - because a direct call bypasses the specification and cannot
see this.

**`normal-auto-fill-function` was a forward reference.** Emacs's `defvar`
holds the quoted *symbol* `do-auto-fill`, which needs nothing to exist
yet; here it holds the procedure, and defining it above `do-auto-fill`
made `fill.scm` unloadable *interpreted* ("Unbound variable:
do-auto-fill") while the compiled `.go` resolved it - so only a run with
no compiled cache showed it. It is `#f` where Emacs declares it and
`set!` after the definition, which also marks it mutable against the
compiler's constant folding.

## The comment continuation, and a parameter that was always true (2026-11-17)

`comment-indent-new-line` (`newcomment.el:1465`) is in, with the four
functions it stands on, so **auto-fill inside a comment repeats the `;;`**
and `comment-line-break-function` has Emacs's real default. Ten fixtures
against Emacs 31.1 are byte-identical (continue at the end, split in the
middle, `comment-multi-line`, a `;;;` doc comment, a comment after code,
one in an indented body, and the three auto-fill cases) and they are in
`fill-tests.scm`'s `comment_line` group.

**Where it lives**: `comment-indent-new-line` and `comment-valid-prefix-p`
are `fill.scm`'s, not `newcomment.scm`'s - the function reads
`adaptive-fill-mode`, `fill.scm` imports `newcomment`, and the Emacs home
would close the cycle for that one variable. The general half
(`comment-search-backward`, `comment-beginning`, `comment-forward`,
`comment-enter-backward`, `comment-styles` and the two defcustoms) is in
`newcomment.scm`, and `syntax-after` (`subr.el:6563`) is in `syntax.scm`.

**The bug worth remembering** is the one this pass found in its own new
code: the guard

    (and (comment-start) *comment-auto-fill-only-comments* ...)

reads the *parameter* without its parentheses, and an uncalled parameter is
a procedure, which is true - so the guard never short-circuited and the
`save-excursion` below it ran on every call. The visible symptom was one
extra byte in a middle-of-comment split (`";;\n;;\naaa bbb"` for Emacs's
`";;\n;;aaa bbb"`); the end-of-comment fixture passed either way. **A
parameter used as a variable is always true**, and a test with point at
the end of the line cannot see it.

Two Elisp-isms the port needed, both named in the source: the C's `let*`
over the five comment **buffer-locals** is a `dynamic-wind` of
`set-buffer-local-value!` (Emacs's `specbind`), and
`(called-interactively-p 'interactive)` is
`(called-interactively? comment-indent-new-line)`.

Still not carried from that half of `newcomment.el`: `comment-dwim`,
`comment-region`/`uncomment-region`, the quoting machinery,
`comment-set-column`, `comment-line` and `comment-kill`.

## `syntax-ppss`'s cache was one global cell (2026-11-17)

Found by `M-j` in a fresh scheme buffer: "Wrong type argument in position
2: #f", three functions from the cause. Emacs keeps **two buffer-local
cells** - `syntax-ppss-wide` and a separate one for a narrowed buffer,
reset when the narrowing's start moves (`syntax.el:525-540`) - and
`pt-min` is `(point-min)`. This tree had one `make-parameter` cell, global
to the editor thread and blind to narrowing, and `pt-min` was `1`. So a
state cached at a high position could be read back at a low one with the
empty buffer's state in it, where Emacs's own `(<= pt-min pos)` test is
`(<= nil pos)` and raises.

`syntax-ppss-flush-cache` is `syntax.el:544`'s now too: **both cells**, the
C's strictly-greater entry rule, and the C's `last`-throwing condition
(the port cleared `last` unconditionally).

**A local `point-min` was missing as well**: `editfns.scm` imports this
library, so `syntax.scm` reads positions through `%point-min`/`%point-max`
beside it - and `syntax-after` (`subr.el:6563`), added this pass, had been
referring to an unbound `point-min` since it was written.

The regression tests are `syntax-tests.scm`'s `ppss_cache` group, and
their expectations had to be measured **with the comment syntax set**:
without `;` = starter and newline = ender in the test buffer, `;` is
punctuation and every state says "not in a comment", which makes the test
look right and mean nothing.

# The narrowing commands, and the repaint they needed (2026-11-17)

Chris: *"I thought you said narrowing was done, but C-x n n seems to do
nothing."* Right, and the handoff wording is what hid it: **the primitive
and the call sites were done; the commands and the keys were not.**
`narrow-to-region`/`widen` were plain functions with no interactive spec,
and nothing had ever bound `C-x n`.

## What is in now

- `narrow-to-region` and `widen` are `define-command`s with the C's own
  interactive specs (`editfns.c:2948`, `:2901`), plus `narrow-map`
  (`bindings.el:1214`).
- `narrow-to-defun` (`lisp.el:742`, `C-x n d`), `narrow-to-page`
  (`page.el:88`, `C-x n p`), `goto-line-relative` (`simple.el:1703`,
  `C-x n g`).
- **The keys are flat** (`C-x n n`, `C-x n w`, ...) because this tree's
  lookup does not descend into a submap - the `mule-keymap` departure,
  recorded again in DEPARTURES.md. `narrow-map` exists as Emacs's object
  beside them.
- `test/narrow-test.scm` (15 tests, every number Emacs
  31.1's) and `tools/pty-check.py`'s `narrow`.

**Not carried**: Emacs disables `narrow-to-region` by default
(`(put 'narrow-to-region 'disabled t)`) and asks "Use this command?"
first; the disabled-command machinery (`simple.el:2821`, `novice.el`)
needs `substitute-command-keys`, which is not ported. So `C-x n n`
narrows at once here.

## The redisplay a narrowing needs

`narrow_to_region`/`Fwiden` set `clip_changed` and `redisplay_internal`
answers by invalidating every window's matrix and redrawing the frame.
Our `%clip-changed!` set `windows-or-buffers-changed`, and `render!` used
that flag only for the menu and tab bars - so **the row diff skipped the
rows a narrowing left unchanged and the screen kept whatever ncurses had,
which after its own clear was nothing**: the mode line stayed, the text
went. `C-x n d` showed it too, so it was narrowing in general, not the
region.

The fix is one `or` in `render!`: a frame is treated as garbaged when
`windows-or-buffers-changed?` is set, so its matrices are invalidated and
its surface cleared as on a resize. **A flag that says "the screen no
longer follows from the matrices" has to reach the matrix
invalidation, not just the menu bar.**

## The three primitives found under it

1. **`inhibit-modification-hooks` was not carried** (its absence was
   written in `with-silent-modifications`' own comment). It is
   `insdel.scm`'s parameter now, tested where the C tests it
   (`prepare_to_modify_buffer_1:2167`, `signal_after_change:2387`), and
   bound by `with-silent-modifications` and `syntax-propertize`. Without
   it a property write during propertizing ran `syntax-ppss-flush-cache`
   over the parse that was computing the properties.
2. **`syntax-propertize` had no in-process sentinel**
   (`syntax-propertize--done` = `most-positive-fixnum`,
   `syntax.el:384/457/547`), so every `syntax-ppss` re-entered the
   propertizer and re-flushed the cache. Ported whole, with the
   extend-region binding and `syntax-ppss--updated-cache`.
3. **`syntax-ppss`'s `last` entry is stored by the OLD-PPSS and `else`
   branches only** - not by OLD-POS. Measured on Emacs: 10 then 13 leaves
   `last` at 10; 15 then 6 leaves it at 6.

And two search bugs `narrow-to-page` walked into: `match-beginning`/
`match-end` raised where Emacs answers nil (`search.c:2776`) and
`(set-match-data nil)` did not clear the registers - both with
regression tests, and the old test that pinned the error now tests the
Emacs answer.

## Method notes

- **A live editor answers questions the headless harness cannot**, and
  the two disagreed here: the `<test-display>` drew the narrowed buffer
  perfectly while the terminal drew nothing. Querying the live editor
  (`window-desired-matrix`, `glyph-row-glyphs`, `window-start`,
  `point-min`/`point-max`, `%window-line-slices`) is what showed the
  matrix was *right* and the diff was the problem.
- When a screen is blank, distinguish **cleared** from **blanked**:
  `blank-glyph-row!` writes spaces and means the desired rows were
  disabled; a cleared screen with correct rows means the diff skipped
  them. The raw escape stream tells the two apart (`\x1b[2J` versus 80
  spaces per row).
- **The pty check I wrote first had its expectations inverted** (I
  assumed the region was [13,18) when `C-SPC C-n C-n` makes it [1,13)).
  It "failed" while the editor was right. Work out what the keys select
  before writing assertions about them.

# A typed RET, and the hook under it (2026-11-17)

`newline` (Emacs 31's `simple.el:621`, not `cmds.c`'s any more) is
ported whole: the `self-insert-command` routing, the `last-command-event`
line, `inhibit-auto-fill`, `use-hard-newlines` +
`set-hard-newline-properties`, the blank line's lost margin, the new
line's `move-to-left-margin`, and the page-start guard. Under it,
`post-self-insert-hook` (`cmds.c:524`) exists and runs.

## What to know before touching it

* **`post-self-insert-hook` is a parameter run with a plain
  `for-each`** - `subr.scm`'s `run-hooks` is above `buffer.scm`, which
  `cmds.scm` imports, so it is not reachable there (same reason
  `auto-fill-chars` lives in `cmds.scm`). It runs at the end of
  `internal-self-insert`, after the auto-fill branch.
* **`newline`'s post-processing is an entry on that hook, and first on
  it**, which is how Emacs gets the hard-newline/margin work done before
  any other hook function. The entry removes itself with a `letrec`
  lambda, as the C removes its gensym.
* **A programmatic `(newline)` runs only that entry; an interactive RET
  runs the caller's functions too.** Measured on Emacs 31.1 and pinned in
  `fill-tests.scm`: `"ab\n"` versus `"ab\n|"` with an insertion hook.
* **Three variables moved down into `simple.scm`**: `inhibit-auto-fill`
  (from `fill.scm`), `page-delimiter` and `use-hard-newlines` (from
  `paragraphs.scm`) - `newline` is their lowest reader, and Emacs has no
  layering. Both libraries import and re-export them; `imports.scm` is
  regenerated.

## The traps this pass paid for

* **A `let`/`letrec` over a parameter's name is not a dynamic binding**
  - it shadows the parameter object with a value, and the next
  `(*name*)` in the body applies that value: "Wrong type to apply".
  `newline` binds all three with `parameterize`; only `postproc` is a
  `letrec`.
* **A test that types its text auto-fills on the way in.** The RET tests
  must `insert` the line and then call `insert-newline`, as Emacs's
  measurement did - `type-text` had already wrapped the line at
  `fill-column`, so the RET had nothing to fill.
* **`(char-after)` with no argument is an error here** (Emacs's defaults
  to point), and it had sat in `newcomment.scm`'s
  `comment-enter-backward` since that file was written. `logand` was
  unbound there too. Both fixed; the compiler's "possibly unbound" and
  "possibly wrong number of arguments" warnings were the only evidence,
  and the full-tree sweep used in earlier sessions had been filtering
  them out.
* **A prefixed import still resolves unprefixed through `module-ref`.**
  `custom-tests.scm` passed a test that the compiler called "possibly
  unbound". Import the name plainly; do not rely on the back door.

## Still not carried

`electric-indent-mode` (so `C-j` is `insert-newline` here where Emacs 31
has `electric-newline-and-maybe-indent`), the abbrev expansion inside
`internal_self_insert`, and the `use-hard-newlines` *mode* (the variable
is a `define-custom` for now).

# `prog-fill-reindent-defun` is in, and prog-mode moved up (2026-11-17)

`C-M-q` (`prog-indent-sexp`) and `M-q` (`prog-fill-reindent-defun`) are
in `prog-mode.scm`, with the four helpers under the second. So M-q in a
programming buffer now reindents the defun in code and fills the
paragraph in a comment or string - Emacs 31's split.

* **`prog-mode.scm` moved above `fill`, `lisp`, `indent` and
  `newcomment`**, because a binding must come after its command and the
  commands call `fill-paragraph`, `forward-sexp` and `indent-region`.
  Nothing in those libraries imports `prog-mode`, `lisp-mode` or
  `scheme`, so there is no cycle - but `lisp-mode` (which imports this
  library) now drags `fill` in transitively. That is the price and it
  is named in the file header.
* **`pos-bol`/`pos-eol` are new in `editfns.scm`** - the C's
  *unconstrained* twins of `line-beginning-position`/`line-end-position`
  (`editfns.c:684`, `:740`). `prog--text-at-point-p` needs `pos-eol`.
* **The two `define-key`s sit at the bottom of the file**, after both
  commands; Emacs's `defvar-keymap` can name functions it has not
  defined yet and a Scheme binding cannot.
* **`prog-fill-reindent-defun-function` is a plain variable** with its
  default `set!` after the definition (the `normal-auto-fill-function`
  shape), not a parameter: Emacs `defvar`s it and nothing `let`-binds
  it.
* **`prog--text-at-point-p` answers positions, not `t`** - nil, 1, 4 in
  the measured cases - and my first test expectations compared booleans
  and failed against correct answers.

`prog-mode-tests.scm` (9) is in `tools/run-suites.py`; every expectation
is Emacs 31.1's output for the same text.

## What is left of the named list

`replace-buffer-contents` turned out to be **obsolete in Emacs 31**: the
machinery is `replace-region-contents` (`editfns.c:1922`, a 310-line
DEFUN) over gnulib's `diffseq.h` (578 lines of Myers diff), plus the
small statics. `replace-string-in-region`/`replace-regexp-in-region`
(`subr.el`) call it. That is a project-sized port, not a small one, and
it is the honest size to plan against.

What is left of the named list is the disabled-command machinery
(`C-x n n`'s "Use this command?" prompt). **Its size was overstated
twice**: `substitute-command-keys` is `help.el:1435` in Emacs 31 (not a
~1000-line `doc.c` walk), and the real dependencies are
`where-is-internal` and `key-description` (both here), `key-valid-p`,
`documentation` and a `\={MAPVAR}` keymap summary (all missing), then
`novice.el`'s `disabled-command-function` and the `command-execute`
hook. The other two entries are done - `simple.el`'s Lisp `count-lines` and the labeled
restrictions, in the two sections below. The list also carried
`narrowing-locked`, **which does not exist in Emacs 31.1** (measured:
`fboundp` and `boundp` are both nil, and nothing in `lisp/` or `src/`
mentions it) - a gap note that overstates, corrected here for the same
reason `pages.scm`'s was.

# `count-lines`, and the `assq` that could not keep its name (2026-11-18)

`simple.el:1800`'s `count-lines` is in `simple.scm`, with the three
readings worth carrying forward:

* **The C helper is `%count-lines` now.** Emacs has two line counters:
  `count_lines` (`xdisp.c:29903`, no Lisp name) and the Lisp
  `count-lines`. The tree had given the C one the plain name with a note
  saying the Lisp one was not ported; with it ported, the Lisp name is
  `simple.el`'s and the C helper takes the `%` (`%kill-buffer`'s rule).
  Every importer is updated, and `%count-lines` moved into
  `(only (schemacs fns) ...)` lists in `editfns`, `indentc`,
  `xdisp`, `minibuffer` and `loadup`.
* **The `ignore-invisible-lines` branch is real here** - dired writes
  the property - but **the renderer does not honour `invisible`**, so
  the count is about the buffer and not the screen. Emacs's first
  branch, `selective-display`, is not carried: the redisplay has no
  selective display for it to agree with. Both named in the source and
  in DEPARTURES.md.
* **`assq` cannot be ported under its own name.** Guile's core `assq` is
  not shadowable by a library import (measured three ways), and Emacs's
  differs exactly where `buffer-invisibility-spec` needs it - non-cons
  elements are ignored, where R7RS raises. So Emacs's is `%assq` in
  `fns.scm`. The rest of the tree still uses the core one; converting
  it (and `assoc`) is the named follow-up, starting at
  `window--state-assq` and `tab-bar--assq`.

`fns-tests.scm` grew both groups (38 passes now), every expectation
Emacs 31.1's own, including the invisible-line table and the
improper-tail `assq` error. Also corrected: `pages.scm`'s note that said
`count-lines-page` waited on `count-lines` - what it waits on is
`ngettext`.

# Labeled restrictions (2026-11-18)

`with-restriction` / `without-restriction`, `internal--labeled-narrow-to-region`,
`internal--labeled-widen`, `point-min-marker` / `point-max-marker`, and the
`editfns.c` stack under them are in `editfns.scm`. DEPARTURES.md has the
C and the measured table; what the next session needs:

* **`narrowing-locked` was never real.** The list carried it; Emacs 31.1
  has no such function or variable (measured). Corrected in place.
* **`widen` and `narrow-to-region` changed behaviour only when a label
  is active** - with none, both are byte-identical to before, which is
  why the existing narrowing tests and the pty `narrow` check needed no
  change.
* **The two macros live in `editfns.scm`, not `subr.scm`** (a named
  placement departure): their bodies call `editfns.c`'s internals, and
  `subr.scm` is below this library. `:label` is a `syntax-rules`
  literal.
* **The redisplay brackets every draw in `%with-outermost-restrictions`**
  (`reset_outermost_restrictions`, `xdisp.c:17440`): a labeled
  restriction must not become visible on display, and the restore uses
  the *current* innermost markers, not a saved value.
* **`erase-buffer` drops a buffer's labels first** (`buffer.c:2490`),
  through `*labeled-restrictions-remove-function*` - a seam because
  `buffer.scm` is below `editfns.scm`. `editfns.scm` installs it at
  load. The C's other cleanup sites (write-region, readevalloop,
  display-line-numbers) have no counterpart here, each named in
  DEPARTURES.md.
* **`save-restriction` now saves labels beside the bounds**; its save
  helper returns `(BOUNDS LABELED)` and the restore puts the labels
  back first, the C's order.

Tests: `editfns-tests.scm`'s `schemacs_editor_editfns_labeled` (15),
every expectation Emacs 31.1's own; the redisplay bracket is pinned by
its C contract, since no Emacs-level call can reach it.

# `replace-region-contents`: done, with the engine under it (2026-11-18)

The engine (`lib/diffseq.h`) is `schemacs/diffseq.scm`; the
DEFUN is `editfns.scm`'s; `replace_range` grew the C's buffer and
`[buf beg end]` forms; and `replace-buffer-contents`,
`replace-string-in-region` and `replace-regexp-in-region` (subr.el's)
are in `replace.scm`, a named placement departure. DEPARTURES.md has
the measured table and the named gaps. **This found a real bug**:
`replace-match`'s buffer path added 1 to registers that are already
1-based, so `\N`/`\&` were shifted one character; fixed with two
`search-tests` regressions.

The recon that preceded it, kept for the trap it records:

* **The C is two pieces.** `replace-region-contents`
  (`editfns.c:1922`, ~310 lines) and gnulib's `lib/diffseq.h` (578
  lines: Myers O(ND) with Eggert's TOO_EXPENSIVE heuristic). The engine
  half is done. The DEFUN half still needs: the two character vectors,
  `set_bit`/`bit_is_set` over bytevectors, `buffer_chars_equal` (the
  quit counter and the time limit, escaping through `call/cc` into the
  continuation the DEFUN installs), the string / buffer /
  `[buf beg end]` source forms, and the trivial-case fallback.
* **The apply phase** walks backwards from `(size_a, size_b)` over the
  two bit vectors, replacing each run with `(vector SOURCE-BUFFER BEG
  END)` through `replace_range`, inside a
  `prepare_to_modify_buffer`/`inhibit_modification_hooks` bracket and
  with one `signal_after_change` at the end.
* **`replace_range` here only takes a string** (`insdel.scm` says so);
  it must grow the C's buffer and `[buf beg end]` NEW forms first.
* **The two subr.el callers** (`replace-string-in-region`,
  `replace-regexp-in-region`, and the obsolete `replace-buffer-contents`
  wrapper, `subr.el:4948-5040`) belong in `replace.scm` - the mirror
  rule would say `subr.scm`, but that library is below `editfns.scm`,
  which is a named placement departure like the labeled-restriction
  macros'.
* **The trap the first attempt hit, so the next one does not**: in
  `diag`, the C's two "find the best diagonal" blocks declare
  `fxybest`/`fxbest` and `bxybest`/`bxbest` in the *same* enclosing
  block, and the final `if` reads all four. In Scheme they are one
  `let` with four bindings - not two `let`s, and not one nested in the
  other. The first draft got this wrong, then the paren chase went past
  the point AGENTS.md allows ("a few attempts, then stop"), so the file
  was deleted rather than left half-working. Write `diag` and
  `compareseq` to a scratch file with stub accessors, compile the
  *block* there, and only then assemble the library.

## The engine's tests, and what they do not cover

`diffseq-tests.scm` (5) proves the script rebuilds its target and is
minimal, over fixed and 400 seeded random pairs, plus both heuristic
paths. It cannot prove the *integration*: which characters are compared
(the two regions' extracted code points, properties ignored), how the
bit vectors are applied to a buffer, and the `max-secs`/`max-costs`
plumbing are all the next step's, and the end-to-end comparison against
`emacs -Q --batch` belongs there - final text, point and marker
positions, and the return value, on the same input pairs.

## What the integration proved, and the one thing it cannot

The DEFUN's twelve-case matrix and the three callers' ten cases all
match `emacs -Q --batch` on final text, point and return value. What is
not tested: marker and overlay *identity* across a non-destructive
replacement (the C's reason for the diff) - `replace_range` moves them
as the C does, but no test pins a marker's position across a hunk;
worth adding when something here depends on it. The `max-secs`
escalation is measured only at 0 (the trivial path); no test forces a
mid-diff abort, which needs a deliberately slow comparison.

# The help primitives (2026-11-18)

`help.scm` (help.el's `substitute-command-keys`, `substitute-quotes`,
`key-valid-p`, `help--key-description-fontified`) and `doc.scm`
(doc.c's `documentation`, `documentation-property`), with the
`help-key-binding`/`fixed-pitch` faces. DEPARTURES.md has the measured
table. What the next session needs for the disabled-command pass:

* **`substitute-command-keys` is in place**, so `novice.el`'s prompt
  strings work. `keyboard.scm`'s `help-echo-substitute-command-keys`
  stub still returns its input unchanged - it can now be a seam: a
  parameter in `keyboard.scm` defaulting to identity, installed by
  `help.scm` (which is above it).
* **`documentation` takes a procedure, a command record's symbol, or a
  symbol carrying `'function-documentation`**; a bare symbol that names
  nothing signals "Void function" and a non-function "Invalid function",
  both measured on Emacs. `novice.el` passes a command symbol - fine.
* **`key-valid-p` is in `help.scm`, not `keymap.scm`** (a named
  placement departure): it needs `string-match-p` and `split-string`,
  both above `keymap.scm`.
* **The 1E forms (`\{MAPVAR}`, `\<MAPVAR>`) are not carried** - they
  need `help--describe-map-tree`. They are left standing in the text.
* **Done since**: `novice.scm` is in with the `run-command` check,
  rmc's `--from-minibuffer` arm, and the two disabled markers
  (`narrow-to-region`, `narrow-to-page`). DEPARTURES.md has the
  measured behaviour. **The trap that cost the most**: a keymap's
  binding for a `define-command` is the command's *procedure*, so
  `*this-command*` at prompt time is that procedure - the name is found
  through `command-record-of`, not by applying `command-name` to it.
  And rmc's choices hold *characters* here where Emacs holds integers,
  so `last-command-event` must be converted with `integer->char` before
  the `assq`.
* **Still missing**: `en/disable-command`'s init-file write (the
  session `put` is carried; `*user-init-file*` now exists in
  `startup.scm`), `ding`, and the rmc modal/dialog arm.

## The disabled-command pass (2026-11-18)

`novice.scm`, the check in `run-command`, `command-query`/
`command-execute--query`, rmc's minibuffer arm, and the two
`(put ... 'disabled t)` markers. Verified: `novice-tests` 7; the pty
battery's new `disabled-command` check (n / SPC / `!`) and `narrow`,
which now answers the prompt it pins. Two things to know before
touching it: `*this-command*` is the bound *procedure* (see above),
and the `disabled` property is keyed by the command's *name symbol*,
which `run-command` derives with `(string->symbol (command-name cmd))`
- a command reached as a procedure (a menu item holding one, or
`%run-command`) never consults the check, as Emacs's Lisp callers
never reach `command-execute`.

# `C-h b` — the describe machinery, and the help buffer (2026-11-18)

The first of the help commands. DEPARTURES.md's 2026-11-18 section has
the C each rule came from and every named gap; this is what the next
session needs to know before touching it.

## What landed

- **`keymap.scm`**: `keymapp` and `lookup-key` (`lookup_key_1`'s walk
  with ACCEPT-DEFAULT and keymap-lists; the "too long" answer is the
  event count). Measured: a `(t . DEF)` entry is a *specific* binding
  when the looked-up event IS `t`, and only the fallback otherwise.
- **`keyboard.scm`**: `*overriding-local-map*` (a parameter), and
  `lookup-keymaps` now applies `current_active_maps`' rule — when it is
  set and the terminal map is not, the lookup is that map and
  `global-map` alone.
- **`editfns.scm`**: `get-local-map` (`intervals.c:2176`), beside
  `get-pos-property`; `buffer-local-value` imported.
- **`faces.scm`**: the `separator-line` face.
- **`simple.scm`**: `make-separator-line`. **`window-width` in this
  tree is the window record's slot accessor, not window.c's DEFUN** —
  the Elisp's `(window-width)` is `window-body-width` here.
- **`help.scm`**: `help-buffer`, `help-setup-xref`, `help--window-setup`,
  `with-help-window`, `help-fns-function-name`, `help--describe-command`,
  `help--describe-map-compare`, `help--shadow-lookup`, `describe-map`,
  `describe-map--align-section`/`-fill-columns`,
  `help--describe-map-tree`, `describe-buffer-bindings`,
  `describe-bindings`, `help-map`, and `C-h b`.
- **`help-mode.scm`** (NEW): the mode and its map, and
  `(*help-mode-function* help-mode)` at load. **A front end must import
  it** — both now do — or `*Help*` is left in fundamental-mode; help.el
  is *below* help-mode.el so the seam is the only way up.
- Tests: `help-tests.scm` 23; pty `help-bindings`.

## The traps this pass paid for, all four of them

1. **`(not '())` is `#f`.** Elisp's `(null x)` must be `null?` here. A
   `(when (or (not shadow) ...))` skipped every map whose shadow was
   the empty list, and the whole description came out blank with no
   error.
2. **A parameter called, a plain variable read.** `*help-mode-function*`
   was written `(define ... #f)` and then called; so was
   `*help-xref-following*`, and `*overriding-terminal-local-map*` (which
   is *deliberately* a plain variable) — each is "Wrong type to
   apply: #f" from inside `with-current-buffer`, several frames away.
3. **`inhibit-read-only` wraps the body.** The C's
   `(let ((inhibit-read-only t)) (erase-buffer) (funcall callback))` —
   putting the callback outside the `parameterize` made every help
   command insert into a read-only buffer.
4. **The help window must be given point-min *before* the display.**
   `temp-buffer-window-show` does `(goto-char (point-min))` before
   `display-buffer`; otherwise the new window shows the buffer's end —
   which for a 200-line description is the last section, and looks like
   "the top of my help is missing".

And one about the key itself: **`q` closes the help window only when
that window is selected** — `display-buffer` does not select
(`help-window-select` is nil, Emacs's too), so the pty check does
`C-x o` first. A check that sends `q` straight after `C-h b` types `q`
into the file.

## What is left in the help pass

- **`C-h f`** `describe-function`, **`C-h v`** `describe-variable`
  (help-fns.el) — `help-fns--signature`, the docstring's usage line,
  `prin1` of a value, the file/line xref (not carried).
- **`C-h k`** `describe-key` (help.el:1045) — `read-key-sequence`, the
  key's binding through `key-binding`, the `M-x NAME` fallback.
- `describe-vector` on a *char-table* (disp-table, syntax tables,
  category sets) — a chartab walk, and the reason `help--describe-vector`
  as a public function does not exist here.
- The `\{MAPVAR}` form of `substitute-command-keys` now has its
  machinery (`help--describe-map-tree`); wiring it is the next piece of
  help.scm's header's first gap.

# `C-h f`, `C-h v`, `C-h k` (2026-11-18, same day as `C-h b`)

## The bug under `C-h k`: `read-key-sequence` always answered `#f`

The three callbacks `%read-key-sequence` hands `modal-lookup-state-step!`
were treated as if their values came back, but the step answers only
"was the chord finished?" - so the function returned `#f` for every
call. The sequence now goes in a variable the callbacks set. Anything
using the `k`/`K` interactive codes was getting `#f` silently; `C-h k`
was the first real caller and showed it as "#f runs the command ...".
**When a primitive's answer travels through callbacks, it needs a
variable, not the call's return value.**

## What landed

- `help-fns.scm` (NEW): `describe-function`, `describe-function-1`,
  `help-fns--key-bindings`/`--insert-bindings`/`--obsolete`/
  `--ensure-empty-line`, `ensure-empty-lines`, `describe-variable`;
  installs `*describe-function-1-function*` and binds `C-h f`/`v`.
- `help.scm`: `describe-key`, `help--analyze-key`,
  `help--filter-info-list`, `help--binding-undefined-p`,
  `help-key-description`, and the seam; binds `C-h k`.
- `keyboard.scm`: `key-binding` takes ACCEPT-DEFAULT and now answers
  the "too long" number like `Flookup_key`; `read-key-sequence` fixed.
- Tests: help-tests 29, pty `help-describe`.

## The three data-model walls in `C-h f`/`C-h v` (read the headers)

1. **No usage line** - a Scheme procedure has no arglist. This is the
   biggest visible difference from Emacs's describe-function.
2. **No file/line** - `find-lisp-object-file-name` has no counterpart.
3. **Variables are Scheme bindings** - only `define-custom` variables
   have a symbol, a docstring and a reader, so `C-h v` completes over
   `custom-variable-names` and a non-custom name says "Not documented
   as a variable." And the custom *symbols carry the asterisks* the
   parameter convention gives them.

## What is left of the help pass

- `C-h c` `describe-key-briefly`, `describe-symbol` (`C-h o`),
  `describe-command`, `where-is` (`C-h w`), `describe-mode` (`C-h m`),
  `describe-syntax` and `describe-categories` (need `describe-vector`
  over a char-table - a chartab walk).
- `help-fns--signature` and `help-function-arglist`, if the tree ever
  gives a procedure its argument names (a docstring convention would
  do it).
- `\{MAPVAR}`'s wiring now that `help--describe-map-tree` exists.
- The menu walk in `help-fns--insert-menu-bindings`.

# `\{MAPVAR}`, `C-h c`, `C-h w` (2026-11-18)

- **`\{NAME}` resolves through the keymap's label** (`keymap-by-name`,
  `keymap.scm`): Emacs reads `symbol-value`, which this tree does not
  have; every library keymap is made with a `'*name-map*` label and the
  registry accepts both the label and its star-stripped spelling, which
  is what docstrings name. String-labelled maps (menus, `help-map`) are
  not reachable - named in DEPARTURES.md.
- **`\<NAME>` scopes `\[COMMAND]`** to that map; measured in help-tests.
- **`C-h c` and `C-h w`** are in, `where-is` without the alias scan.
- **Two traps paid for (again)**: a command's interactive expression
  runs in its *defining* module - `where-is` needed `read-command`
  imported into help.scm, and without it `C-h w` was a silent echo-area
  error; and a parameter named `insert` shadows `insert` (renamed
  `insert-flag`, the `minibuffer-message` TEXT precedent).

Left in the help pass: `C-h o` describe-symbol, `C-h m` describe-mode,
`C-h s`/`describe-vector` over char-tables (a chartab walk), and the
menu walk in `help-fns--insert-menu-bindings`.

# `C-h m` describe-mode (2026-11-18)

- **`define-minor-mode` now keeps `local-minor-modes`/`global-minor-modes`**
  as Emacs's generated command does - the lists hold the mode's *symbol*
  here (the alist's key), not the function symbol. `*global-minor-modes*`
  is a parameter in subr.scm beside `*minor-mode-list*`.
- **`describe-mode`** reads them for the "Minor mode enabled in this
  buffer:" section, then the major mode's name and documentation - which
  is where `\{mode-map}` finally substitutes - then the global modes.
  The indicator line reuses xdisp's `minor-mode-indicator-value` /
  `minor-mode-lighter` (now exported) rather than re-walking the alist.
- **Two traps, both about compiled images**:
  1. a macro template resolves names in the *expanding* library, and
     under interpretation an unimported core binding is unbound
     (`delq`); the suite runner's fresh cache runs source, so **when the
     runner and a direct run disagree, the runner is right**;
  2. after changing a macro, every library that *uses* it must be
     recompiled - `fill.scm`'s `.go` kept the old expansion and made
     `auto-fill-mode` look broken until the tree-wide sweep ran.

Left: `C-h o` describe-symbol, `C-h s`/`describe-vector` over
char-tables, the `help-fns--insert-menu-bindings` menu walk.

# `C-h s` describe-syntax (2026-11-18)

- **`describe-vector` (help.scm, a placement departure) walks
  char-tables**: the two-pass range walk, `char-table-ref-and-range`,
  `indent-to 16`, the `default` row. Its vector path is not carried -
  this tree's keymaps are records.
- **`internal-describe-syntax-value`** is help-fns.scm's (syntax.c's
  DEFUN, but it inserts and calls substitute-command-keys); syntax.scm
  now exports the `SYNTAX_FLAGS_*` readers for it.
- **`C-h s`** is bound and pty-checked. Measured: the standard table's
  first three dozen rows are byte-identical to Emacs's.
- **The two tail differences, both named in DEPARTURES.md**: the
  high-plane syntax runs stop around U+1F3FF in `characters.scm`
  (`standard-syntax-runs` - a transcription gap worth re-running over
  the whole character space), and eight-bit characters print as
  `[N]` where Emacs writes raw bytes (the standing departure).
- **Trap**: a parameter named `vector` shadows the `vector`
  constructor - `(vector x)` applied the char-table. Build keys as
  lists.

Left in the help pass: `C-h o` describe-symbol, `C-h ?`/help-for-help's
`C-h i` alternatives, the menu walk in `help-fns--insert-menu-bindings`,
and `describe-categories` (the category table itself is not ported).

# `C-h o` describe-symbol, and `(scheme base)`'s read-string (2026-11-18)

- `describe-symbol` is in help-fns.scm with two backends (command,
  custom variable); the multi-backend loop is carried but unreachable -
  in a Lisp-1 a name cannot be both. Its prompt completes over the
  command table + `custom-variable-names`.
- **`(scheme base)` exports Guile's `read-string` `(len #:optional
  port)`, and it silently wins an import against minibuffer's prompt
  `read-string`.** Calling it as `(read-string "PROMPT")` raises "Wrong
  type (expecting exact integer)" from `make-string`. `(except (scheme
  base) read-string)` on the importing library **does not fix it**
  (measured). Use `completing-read`, or the `*read-string-function*`
  seam.
- C-h o is pty-checked; all nine help keys (`b f v k c w m s o`) now
  run through the real command loop.

# The suite runner is parallel by default (2026-11-18)

`tools/run-suites.py` now runs suites in a `ThreadPoolExecutor`
(`-j N`, default 4; `SUITES_JOBS` sets it; `-j 1` is the old serial
run), and it is safe for a measured reason:

- **Every suite is its own `guile --no-auto-compile` process** and
  writes *nothing* to the shared `XDG_CACHE_HOME` - that is the same
  flag that makes a suite run from source, so there is no compiled file
  to race over.
- **The fixed `/tmp` paths are per-suite**: every duplicated path in
  the test files (`/tmp/x.txt`, `/tmp/mbext/...`) belongs to exactly
  one suite (checked with `grep -rho '"/tmp/...' | sort | uniq -c`).
  Two suites never share one, so parallel processes cannot clobber each
  other's fixtures.
- **Output stays in the list's order** - all suites are submitted at
  once and the lines are collected in `paths` order - so two runs'
  logs still diff, and a straggler only delays the lines after it.

Measured on this 16-core machine, full run: serial (`-j 1`) **108 s**,
`-j 4` **38 s**, `-j 8` **29 s**, with the per-suite pass counts
identical in all three (diffed line by line). `pgtk-tests` (8.6 s, the
lone GTK suite) sets the parallel floor. The suite runner's old "~10
minutes" reputation was measured on a loaded machine; the work itself
is ~2.5 s a suite here.

**The pty battery is not part of this and must still run alone** - it is
timing-sensitive (the settle logic), and running it beside the suites
is the documented flake.

# The pty battery is 21% faster, and what the rest of it costs (2026-11-18)

Two fixed sleeps in `drive()` were removed, and nothing else changed:

- **The startup floor `settle=1.5` is now 0.3.** The floor predates the
  draw-and-quiet rule; with that rule in place it was a second of dead
  time on every one of the ~200 `drive()` calls - the readiness test is
  "a screen has been drawn and the editor has been quiet for QUIET",
  which the 1.5 was only ever a guess at.
- **The last ordinary key is no longer settled per key.** Its
  `settle(gap)` waited for exactly the quiet the end-of-drive loop waits
  for, over the same bytes, so every check paid 0.3 s twice.

Measured full battery, same tree, same machine:
**981 s before, 770 s after, 95/95 both times.** `grep gap=` showed the
`gap` values other checks pass are 0.12-0.4, all ≤ QUIET, so dropping
the last key's settle is equivalent-or-longer for every one of them -
**except `completion-ui`, which used `gap=3.0` on its last key as a
semantic wait for `minibuffer-message-timeout`**, and went red the
moment the harness stopped sleeping there. It waits with an explicit
`("sleep", 3.0)` key now. The rule to carry: **`gap` is pacing; a check
that needs a wait says `WAIT`/`sleep`/`EXITED`, never a big `gap`.**

## What the remaining 770 s is

Per `drive()`: the editor's own start, one `settle(gap=0.3)` per key
*element* (bulk of it - ~1.5-2.5 s a drive), and the end quiet wait
(0.4 s). So the two ways down further are known and both are bigger
jobs than this one:

1. **Per-check `WAIT` threading** - the documented fix: every check says
   what its next key is about instead of letting the harness pace.
   Saves the per-key 0.3 s on the *first* key after each expectation
   arrives, but only where the check can name it; ~90 call sites.
2. **Reuse one editor across a check's `drive()` calls** - several
   checks call `drive()` four times and pay four editor starts; each
   call's fresh state is deliberate, so this is a redesign of those
   checks, not a harness tweak.

# The pty battery, second pass: 981 s -> 528 s (2026-11-18)

The first pass (the section above) removed two fixed sleeps and got 981 ->
770 s. This pass was aimed by **measurement**: `SCHEMACS_PTY_PROFILE=1`
makes `drive()` count its own phases and print them at exit -

    pty profile: 219 drives, 1066 key elements; startup 222.1s,
    key pacing 388.0s, end waits 103.5s, kill tail 0.0s

- which said the per-key pacing was half the battery. That value was the
`gap=0.3` "quiet between keys", and the question it raised - **can a
key be queued behind the previous one, as a fast typist does?** - was
answered by experiment rather than by argument: the seven checks this
file has ever called flaky, five runs each at `PTY_GAP=0.05`, then full
batteries.

| | settings | time |
|---|---|---|
| baseline | gap 0.3, floor 1.5, quiet 0.4 | 981 s |
| first pass | floor 0.3, no last-key settle | 770 s |
| + gap 0.05 | | 632 s |
| + startup/end quiet 0.2 | **528 s** (two runs, 528 and 528) | |

**95/95 on every one of the four full runs after the change** (one at
`PTY_GAP=0.05`, one with all three knobs explicit, two at the new
defaults).

## The knobs, and what is left

`PTY_GAP` (default 0.05), `PTY_STARTUP_QUIET` (0.2), `PTY_QUIET` (0.2)
and `SCHEMACS_PTY_PROFILE=1` are the experiment surface; the profile
split at the new defaults is **startup 178 s, key pacing 250 s, end
waits 52 s**, rest ~50 s. So:

- the remaining **250 s is the editor's own response per key**, not
  harness sleep - `gap` is nearly exhausted;
- **startup 178 s** is 219 editor starts (0.8 s each: floor + first
  draw + quiet);
- **52 s** is the end waits.

Further means the two bigger jobs named above - per-check `WAIT`
threading (each key waits for the text it provokes, so the pacing
settle is skipped where an expectation exists) and reusing one editor
across a check's drives. **Pushing the quiet values below 0.2 was not
done**: four green runs is not evidence for a fifth of the margin, and
the battery's own history is that the margin is what a loaded machine
spends.

# The window start after `C-x n n`, and the frame crash it caused
# (2026-11-18)

Chris, from the Gtk editor: `C-x n n !` and a backtrace ending
`char-display-width #f 0`, under `scroll-to-cursor!` ->
`%window-line-rows` -> `line-texts-rows`.

## The departure

`narrow-to-region` moves `BEGV`/`ZV` and, like Emacs, leaves markers
where they were - **markers are not clipped by narrowing**, measured on
Emacs 31.1: `window-start` is still 1 after narrowing to 9..15. Emacs's
redisplay clips the local `startp` before laying anything out
(`redisplay_window`, `xdisp.c:20781`: "if (CHARPOS (startp) < BEGV)
SET_TEXT_POS (startp, BEGV, BEGV_BYTE); else if ... > ZV ...") and
clips a window's point the same way (`:16812`). `scroll-to-cursor!`
used both raw, so with the start above `BEGV` it walked lines from
position 1, `fetch-char` answered `#f` below `BEGV`, and that `#f`
reached `char-display-width`, which calls `char->integer` on it.

**The terminal showed the same bug as a blank text area, not a crash.**
There the window's matrix was still valid, so
`scroll-to-cursor!`'s fast path returned before the walk, and
`display-window!`'s own clamp (`%window-start-set!` to
`[point-min, point-max]`) redrew the window from the restriction. The
Gtk frame had an invalid matrix, took the walk, and died. The same
departure, two front ends, two symptoms.

## The fix

`scroll-to-cursor!` clips PT and START to `[buffer-beg, buffer-z]` - a
`max`/`min` pair where the C's two `clip_to_bounds` are - before the
visibility decision. Nothing else moved: `display-window!` already
clamped the marker it writes, which is why a narrowed buffer mostly
drew correctly.

## Verified

- New group `schemacs_ncurses_editor_narrow_start` in
  `tty-editor-tests.scm` (2 tests): the window's start is the
  restriction's beginning, and the cursor is on row 0 of the narrowed
  window. Emacs's own answer for the same buffer/narrowing was measured
  first ("bbb\nccc" from `BEGV`, no trailing newline - `ZV` is 12, so
  the newline at 12 is outside).
- The first test was seen **failing without the fix**, with the user's
  own error: `char->integer` ... irritants `(1 "character" #f)`.
- pty, the user's keys: `C-x n n ! !` on a mid-buffer region draws
  "bbb"/"ccc" (before the fix the text area was blank).

**And `C-x n n` asks "Use this command?" now** - the disabled-command
machinery from the help pass - so the `!` in Chris's paste was the
answer to that prompt (use and enable all), not a keystroke into the
buffer. `n` declines, which is what the harness's first reproduction
did, and why it looked like narrowing "did nothing".

# `compile-file` without the shared site path leaves the UI interpreted
# (2026-11-18)

The compile recipe in this file was

    guile -L . -c "(compile-file \"$f\")"

`schemacs/ui/tty/sysdep.scm` imports `(scheme-utils repl server)`, and
that lives under `$XDG_DATA_HOME/guile/site/3.0` (the Makefile's
`SHARED_SITE`) - which Guile does not search by default. Without `-L
$SITE` the compile fails with "no code for module (scheme-utils repl
server)"; with the loop's stderr sent to /dev/null the failure is
invisible and the file is simply **not compiled**. `bin/se` passes
`--no-auto-compile`, so the editor then loads that library *as source*
and runs it interpreted.

Measured, the same tree and battery: **1.33 s of startup per drive
with the UI interpreted, 0.52 s compiled** - and `pty-check.py`'s
`quit-signal` failed 3/3, because a key sent while the startup's
`xterm--query` is still round-tripping is discarded by
`tty-flush-query-input` (Emacs's own `flushinp`, `xterm.el`'s "Pending
input can be mistakenly returned ... discard it"). With the tree
compiled it passed 5/5.

The recipe is therefore

    SITE=${XDG_DATA_HOME:-$HOME/.local/share}/guile/site/3.0
    find schemacs -name '*.scm' | while read -r f; do
      guile -L . -L "$SITE" -c "(compile-file \"$f\")" || echo "FAILED $f"
    done

**and a compile failure must be reported, not swallowed** - a library
that fails to compile is a library that will run interpreted, which
looks exactly like the editor being slow.

# The tab line's group table, the "+" button, and `event-start` for a key
# (2026-11-18)

Three reports in a row, all from turning the tab line and the tab bar on:
`C-x <right>` gave "Wrong type argument in position 1 (expecting struct):
#f", `tab-line-tabs-buffer-groups` died with "unbound variable:
*tab-line-tabs-buffer-groups*", and the tab bar's "+" button gave "Wrong
type argument in position 2: #f".

## `event-start` of a keyboard key

`tab-line-switch-to-next-tab` is bound to `C-x <right>` by
`tab-line--define-keys` (which `global-tab-line-mode` runs), and its body
is `(with-selected-window (posn-window (tab-line-event-start event)) ...)`.
Emacs's `last-nonmenu-event` at that point is the **key event** - an
integer or a symbol, not a posn - and `event-start` handles that:
`subr.el:1938`'s "or ... `(event--posn-at-point)`". Ours had been
simplified to `(and (pair? event) (nth 1 event))`, with a docstring
claiming #f "is the shape every caller in this tree wants". That was true
until the first caller that runs from a *key* and wants a position;
`posn-window` then got #f and the command died.

Ported bottom up:

- **`posn-at-point`** (`keyboard.c:13594`) in `xdisp.scm`. The C asks
  `pos_visible_in_window_p` for the glyph's pixel coordinates and hands
  them to `posn_at_x_y`; this asks the row walk the cursor is placed with
  for the position's screen row and column and hands *that* to
  `posn-at-x-y`. Answers nil with no display object - the help suites run
  headless - which is the "not on screen" answer.
- **`event--posn-at-point`** (`subr.el:1894`) - **`subr.el`'s function in
  `xdisp.scm`**, a named placement departure: it needs a window and
  `posn-at-point`, both above `subr.scm`, so it arrives through the seam
  `*event--posn-at-point-function*`, which `xdisp.scm` installs at load.
- `event-start` and `event-end` now take Emacs's second arm for anything
  that is not a cons.

Verified live: with `global-tab-line-mode` on, `C-x <right>` runs
`tab-line-switch-to-next-tab` and switches the window with no error; with
it off the same key still runs `next-buffer`.

## `*tab-line-tabs-buffer-groups*` was exported and never defined

`tab-line.el:499` is a `defvar` whose default is
`mouse-buffer-menu-mode-groups`; the tree's tab-line header even said it
was "a parameter at the top of this section" - but there was no
`define`. So `tab-line-tabs-buffer-group-by-mode`, `tab-line-new-tab`
and `tab-line-format-tabs-groups` all died with `unbound variable` the
first time a user turned the tab line on with the grouping tab-list
function. **An export of a name the library does not define is an
unbound variable in every importer** - the same class `loadup-tests`'
clash census found for `casefiddle`'s `upcase-region`.

Three follow-ons, all found while making it work:

- `*mouse-buffer-menu-mode-groups*` is a **plain variable** in
  `mouse.scm` (Emacs `defvar`s it), despite its stars; the new
  parameter's default reads it by name, not by calling it -
  `(*mouse-buffer-menu-mode-groups*)` applied the alist and died with
  "Wrong type to apply".
- `(format-mode-line mode-name)` passed the *procedure* `mode-name` to
  the formatter, because Emacs's variable is this tree's accessor, so
  every mode grouped under the empty string. It is `(format-mode-line
  (mode-name))` now.
- Eight `(cdr (assq 'key tab))` sites broke on a **group tab**, which
  has no `buffer` or `selected` entry: Emacs's `(cdr nil)` is nil and
  Scheme's is an error. They use this file's own `alist-get`, which
  answers #f.

## The "+" button ran the command with no arguments

`tab-bar-mouse-1` had `((list-ref-or-false item 1))` where
`tab-bar.el:417` has `(call-interactively (nth 1 item))`. The item's
command is the **symbol** `tab-bar-new-tab` in the menu-item form, and
its two arguments come from its interactive specification - so a bare
call is "Wrong number of arguments"; a symbol is also not a
`procedure?` here, so the branch's guard skipped it and the click did
nothing at all.

**`call-interactively` (`callint.c:253`) was missing.** It is in
`command.scm` now: a command record, a procedure or a symbol, run
through `run-command` - which is this tree's `command-execute` (it does
the disabled check). `tab-bar-mouse-1` uses it, and its guard accepts a
symbol naming a command, which is what Emacs's `functionp` is over an
obarray.

Verified: clicking the "+" cell adds a tab. `tab-bar-tests.scm` clicks it
through `posn-at-x-y` + `tab-bar-mouse-1` and asserts the tab count goes
2 -> 3.

## Also: `set-fill-column`'s prompt printed `%s`

`(format #f "Change fill-column from %s to: " ...)` - Guile's `format`
takes `~a`, so the prompt read literally "Change fill-column from %s
to: ". Fixed.

## Tests

- `mouse-tests` +2 (45): `event-start` of a key answers the selected
  window's posn; `posn-at-point` answers the window for an on-screen
  position and nil for one that is not.
- `tab-bar-tests` +1 (45): the "+" click adds a tab.
- `tab-line-tests` +1 (17): the group table is a parameter, and a
  fundamental buffer groups under "Fundamental".
- All 71 suites pass, the tree compiles, and `tools/pty-check.py` is
  green on this tree.

**The "+" message Chris saw was not reproduced on this tree**: after the
`call-interactively` fix the click works, and "Wrong type argument in
position 2: #f" did not appear anywhere in the reproduced sequence. His
editor was running code from before these fixes - a running editor keeps
the code it started with - so a restart is the first thing to try, and a
backtrace is the second.

# The pty battery's per-key timing, third pass: the slow keys were the
# harness itself (2026-11-18)

Chris: *"I've noticed that editor response per key is very slow, is there
a reason for that?"* Measured, and the answer is no - the editor answers a
key in single-digit milliseconds; the slowness was the battery's own
per-key pacing.

## What the profile says now

`SCHEMACS_PTY_PROFILE=1` gained per-settle instrumentation:
`wait_quiet` records, for every settled key, **the time to the first
byte, the time to the last, and the number of reads**, and the report
prints them:

    response to first byte: 0.1s over 18 settled elements (3 ms each);
      last byte at 11 ms each over 28.6 reads
    per-key settle: min 52 ms, median 56 ms, p90 85 ms, max 86 ms over 15

So the editor's own response to a keystroke - the command loop, the
redisplay and the terminal flush - is **1-3 ms to the first byte and
2-11 ms to the last**, and a settled key costs the harness's 50 ms quiet
window and nothing more.

## What the 350-410 ms "slow keys" were

Before the pass, the report listed slow keys - `C-x d` 360 ms, `C-a`
352, `X` 404, `C-x C-c` 410 - all in the band 350-410 ms. Every one of
them had first byte 1-2 ms and **last byte 2-11 ms**, and still took
~400 ms to settle: the time was spent *after* the editor had finished.
They were the checks' `gap=` value - a per-key *pacing* sleep, a leftover
from the era when every key was followed by fixed sleeps - and 45 call
sites across 28 checks were still passing 0.25-0.4 s.

All 45 were removed (the default is 0.05 s). The two checks whose next
key acts **on a prompt** - `dired`'s `C-x d … C-a` and `save-y-n`'s
answers - say `WAIT` for the prompt text instead, which is the rule this
file already carries: *a check that needs a wait says `WAIT`/`sleep`/
`EXITED`, never a big `gap`.*

## Also: `wait_quiet` is silence from the last byte

`settle` used to ask `drain(0.05)` for a whole empty 50 ms window *and*
the window that collected the response, so one settled key cost ~105 ms
whatever the editor did. It is one `wait_quiet(quiet_for, longest)` now:
each select waits only the time still missing before the quiet period is
true. The startup wait and the end-of-drive wait use the same function,
and the cursor blink is turned off in the harness's init so a repaint
cannot land in a quiet window (a de-jitter measure - measured, it was
*not* the cause of the 400 ms outliers).

## Measured

The 28 affected checks pass at the default pacing, and the 20
prompt-typing ones **20/20 under load average ~8**.

**A compile trap found on the way**: the tree-wide compile recipe used
`-L .` only, and `schemacs/ui/tty/sysdep.scm` imports
`(scheme-utils repl server)` from the shared site directory. The compile
failed silently ("no code for module") and the editor then ran that
library *interpreted* - 1.33 s of startup per drive instead of 0.52 s.
See the section above; the recipe needs `-L "$SITE"`.

## Clicking a tab ran the internal function with nil (2026-11-18)

Chris, the next click: **a tab** in the tab bar gave "Wrong type argument
in position 1: #f". `tab-bar-mouse-down-1` called
`tab-bar-select-tab-internal` where `tab-bar.el:402` calls the *command*
`tab-bar-select-tab`. Clicking the **current** tab hands a nil
TAB-NUMBER - `tab-bar--key-to-number` answers nil for the `current-tab`
key - and the command translates nil through `last-command-event` to 0,
"the tab I am on"; the internal function starts with `(< tab-number 0)`
and died on it. The mouse-down handler calls the command now, as Emacs
does. `tab-bar-tests.scm` clicking the current tab and asserting the
buffer stays put is the regression test (46 tests).

**And the reason both of these were still visible to Chris at all**: his
Gtk editor was started before the fixes and a running editor keeps the
code it started with. `guile --no-auto-compile bin/se -w …` was still up
with yesterday's tree; a restart is what picks the fixes up.

# The tab line's row, the tab bar's X, and the popup that said "menu"
# (2026-11-18)

Five reports in one session, and three of them were real departures - one
of them a *primitive* that had never been ported, which is the one worth
reading first.

## The tab bar's close button was not at the end (and was not a button)

Chris: *"in real emacs tab-bar-mode the X is at the end of the tab.
Schemacs has the title, an X then a big space until the end of the tab."*

`tab-bar-tab-name-format-close-button` (`tab-bar.el:897`) is
`(concat name tab-bar-close-button)`, and the button's `close-tab` text
property is what tells `tab-bar-auto-width` where to put the padding
(`:1431`: `ins-pos` is the end of the name, i.e. the caption minus the
button) and what tells a click on the X to close the tab. Ours was
`string-append`, which drops properties - so the padding went *after* the
X and a click on it was not a close.

That was only half of it: with `concat` in place the property still did
not survive, because **the padding loop itself rebuilds the caption out of
`substring`** (`:1444`) - and Scheme's `substring` is, in Emacs's
vocabulary, `substring-no-properties`. Emacs's `substring` is
`substring_both` plus `copy_text_properties`, so it keeps them.

So **`%substring` is in `fns.scm` now** (fns.c:1579), with Elisp's
negative/nil argument rules and the interval tree copied through
`copy-intervals`. It is `%`-named because a core binding cannot be
shadowed - the `%assq` rule (`fns.scm:463`) - and the tree still uses
Guile's `substring` everywhere else. **Wherever a ported Elisp that Emacs
wrote with `substring` may hold a propertized string, use `%substring`**;
Guile's is `substring-no-properties` and loses faces and keymaps
silently.

## The tab line went blank after `C-x <left>`/`C-x <right>`

Chris: *"in tty mode if I open a file it's showing one tab-line tab. If I
hit C-x <left> and C-x <right> the title of the tab and the content of the
buffer changes, but only one tab"* - then, having looked again: *"the
tab-line bar disappears and the tab-bar tab changes names, which is
correct, but it makes it look like only one tab, when the problem is
really that the tab-line tabs disappeared."* Exactly right.

The redisplay skips a mode line or tab line whose freshly formatted string
its record says it already drew. The record was compared with `equal?`,
**and Scheme's `equal?` ignores text properties** - while a window
switching between two buffers formats the *same characters* with a
different current-tab face. So the skip fired on a row that had just been
wiped, and the row stayed blank.

Two changes, both the C's answer to a different question:

* **`equal-including-properties` is ported** (`fns.scm`, fns.c:2823) over
  **`compare-string-intervals`** (`intervals.scm`, intervals.c) - the
  recursive comparison `internal_equal` makes under
  `EQUAL_INCLUDING_PROPERTIES`. Both skips use it now.
* **`mark-window-display-accurate-1` clears `last-tab-line`** when a
  window's display goes inaccurate, as it already cleared
  `last-mode-line`: a cache is only good while the screen still holds what
  it records.

Verified end to end: `tools/pty-check.py`'s `tab-line` check gained the
`C-x <left>` `C-x <right>` round trip, and with the fix reverted it fails
with the user's own screen:

    the tab line disappeared after C-x <left> C-x <right>:
      ['File Edit Buffers ...', '  ...', 'the file ...']

## `set-buffer-major-mode` had no caller at all

A buffer made by `C-x b NAME` never ran a major mode, so it never ran
`after-change-major-mode-hook` - and therefore got no
`define-globalized-minor-mode` at all: no font-lock, no `tab-line-mode`.
Emacs calls `set-buffer-major-mode` (`buffer.c:2283`) from
`window-normalize-buffer-to-switch-to`'s create branch
(`window.el:9519`), and ours was ported in `files.scm` but called from
nowhere.

It cannot be called from `window.scm` (a mode command is found through the
command table, which is above it), so **`*set-buffer-major-mode-function*`
is `window.scm`'s seam** and `files.scm` installs it as it loads, beside
its other installs. Same shape as `*read-buffer-to-switch*`.

## The splash window has no tab line - and Emacs's does not either

Chris: *"if I open schemacs with global-tab-line-mode turned on in the
init file, and a file on the command line, it opens with 2 windows and the
bottom window doesn't have a tab-line."*

**Measured on Emacs 31.1 first, and it is the same there.** A GUI startup
was simulated on a tty (`initial-window-system` set before the file
argument, so `command-line-1` keeps the splash) and the windows were
asked:

    ("nb1.txt"      tab-line-height 1  text-mode        tab-line-mode t)
    ("*GNU Emacs*"  tab-line-height 0  fundamental-mode tab-line-mode nil)

The splash buffer is made by `get-buffer-create` and never runs a mode, so
`global-tab-line-mode`'s `after-change-major-mode-hook` entry never reaches
it (`define-globalized-minor-mode`, `easy-mmode.el:568`, walks
`buffer-list` only when the switch is thrown - and the splash does not
exist yet). Ours matches, and `set-buffer-major-mode` above does not change
it: the splash is not created through `switch-to-buffer`.

## Every Gtk popup had an extra level, and it was called "menu"

Chris: *"if I click on the '+' in tab-line mode it opens a menu containing
only the word 'menu'. and the buffer menu is in its submenu. But in real
emacs clicking the + brings up the buffer menu directly."*

`pgtk-menu-show` builds a `widget_value` tree whose root is named "menu"
(`menu.c:619`'s `first_wv->name = "menu"`) and then hands it to
`create_and_show_popup_menu`, which calls `xg_create_widget` - and **the
menu branch of `xg_create_widget` is `create_menus (val->contents, ...)`**
(`gtkutil.c:3575`): the root *is* the GtkMenu, its children are the first
level. Ours passed the root, which made it a menu item.

This affected **every** popup on a Gtk frame - `x-popup-menu`, the Menu
button, the tab line's `+`, the context menus - not just the one he
clicked.

Verified live on a broadway display, by building the same tree twice and
reading the built GtkMenu's children:

    passing the root       -> ("menu")        ; his report, exactly
    passing its contents   -> ("P1" "P2")     ; the two panes

## Two fidelity details found underneath

* **`%substring` validates its range** the way `validate_subarray`
  (`fns.c:1550`) does: a negative index counts from the end and an
  out-of-range or inverted range *signals* rather than clipping. Measured
  on Emacs 31.1: `(substring "abcdef" -9)` and `(substring "abcdef" 5 2)`
  both raise `args-out-of-range`.
* **`set-buffer-major-mode` chooses from the *default* of `major-mode`,
  not from the target buffer's own mode.** The port read the target
  buffer, so `C-x b fresh` in a Scheme buffer made a Scheme buffer where
  Emacs makes a Fundamental one (measured:
  `(window-normalize-buffer-to-switch-to "fresh")` from `text-mode` is
  `fundamental-mode`). The buffer-defaults table is not carried; every
  reader here spells `fundamental-mode` out, and so does this now. The
  C's nil-default fallback is carried for shape and is unreachable, as it
  is in an Emacs that has not `setq-default`-ed `major-mode` to nil.
  `*initial-major-mode*`'s default is `lisp-interaction-mode`, as
  `startup.el` has it - it is what a *created* `*scratch*` takes.

## Battery

`tools/pty-check.py` **95/95** on the settled tree (the final run, after
every change above; the pacing profile below is that run's). The pacing work from
the previous pass shows up in the profile: key pacing **68.5 s** (it was
388 s before the 45 `gap=` values were removed), startup 197.8 s, end
waits 42.8 s. All 71 suites pass (`tab-bar-tests` 47, `fns-tests` 41,
`files-tests` 31, `tab-line-tests` 31). One run before the last two fixes
gave 94/95 with `quoted-insert` red; it passes 3/3 alone on the same tree
and its failure screen was the pre-keypress one ("Blink Cursor mode
disabled"), which is the battery's documented startup-race class, not a
regression.

`%substring` and `*set-buffer-major-mode-function*` are in the generated
`imports.scm` - **re-run `tools/gen-imports.scm`** after adding an export,
or M-:/the REPL/init files cannot see it.

## Method note

The user's three symptoms were one bug seen from three sides, and the
tempting first guess - "the tab list is wrong" - was wrong: the tab list
was right the whole time, and the *row* was not being drawn. Printing the
screen after each key (`File Edit Buffers` / tab bar / blank row / text)
is what separated them; the report's "only one tab" was the tab bar's one
tab showing through a missing tab-line row.

# The line-break cache under a narrowing (2026-11-18, same day)

Chris: *"If I select a region then do C-x n n to narrow. Then I type one
character, a bunch of the text moves around ... If I then do C-x n w to
widen, it's a hell of a mess, the top of the file is filled with garbled
lines with the string ^J between them."*

Reproduced exactly at a pty, and the buffer was innocent - it was the
redisplay drawing the rest of the file as one line. The line-break cache
(`buf->newline_cache`) stores facts about *characters*, and every entry
point of `region-cache.c` reads `BUF_BEG`/`BUF_Z`; this tree passed
`BEGV`/`ZV` from three places, which agree until something narrows. An
insertion while narrowed then shifted the cache's stored basis, and after
widening a "no line break here" run covered text it had never scanned.

Fixed in `region-cache.scm` (`new-region-cache` now takes both text ends),
`search.scm` (the scans pass the text's ends to the cache; the scan itself
still stops at ZV/BEGV) and `insdel.scm` (`beg_unchanged` and the
head/tail counts are text-relative). DEPARTURES.md has the C.

**The reproduction needs the redisplay**: show the file, narrow, edit,
*redraw while narrowed*, widen, redraw. A direct `find-newline` test
passes either way, because it is the renderer's line scan that records the
stale knowledge. The regression is
`schemacs_ncurses_editor_narrow_cache` in `tty-editor-tests.scm`, and
`pty-check.py`'s `narrow` now types a character and asserts no `^J` and no
joined lines; both were seen failing with the old endpoints.

There is also a tab-line crash from the same session, in the same area of
work - see the next section.

# The tab line's clicks, and the `list-tail` that took the redisplay with
# it (2026-11-18)

Two reports from using the tab line with real buffers:

* *"clicking on the tab-line tabs doesn't seem to always activate them.
  The first one yes I think, not the others"*, and *"If I click the x on
  the tab line it is wrong type argument in position 2: #f."*
* *"selecting a buffer from the menu buffer list"* gave a backtrace
  ending `In procedure list-tail`.

## The click

`tab-line-select-tab` and `tab-line-close-tab` read the clicked string's
`tab` property with `tab-line--get-tab-property`, which looks at
positions 1 and 0 - the shape of **one tab's string** (separator + tab).
GNU Emacs's redisplay stores one `(STRING . POS)` per string that
`format-mode-line` lays out (`store_mode_line_string`), so a click's
object is that tab's own string. This renderer formats the whole row into
one string, so position 1 was always the *first* tab: every click
selected it, and every close button closed it.

`posn-at-x-y`'s tab-line branch now rebuilds the segment with
`%tab-line-string-at`: the run of one `tab` value, starting one character
earlier (the separator), answered with the click's index within it. A
click on a separator belongs to the tab after it, as Emacs's would. The
run is walked rather than asked of `previous-single-property-change`,
which answers nil at the first character of a run (measured on Emacs).

Tests: `tab-line-tests`' `posn_click` group clicks posn-a's *name* while
the window shows posn-b (clicking the first tab cannot tell the bug from
the fix - position 1 is the first tab either way), and closes posn-a's
`x`; both fail with the whole-row object (`actual-value: posn-b`,
`(#f #t)`).

## `list-tail` is not `nthcdr`

`tab-line-format-template` cuts the tab list at the hscroll position with
`nthcdr`, and Elisp's `nthcdr` answers nil past the end where Scheme's
`list-tail` is an error. Selecting a buffer from the buffer menu can leave
`tab-line-hscroll` naming a column of the *old*, longer list, and the
reformat died inside the redisplay - the backtrace's `list-tail` with the
tab strings as its first argument. It is `nthcdr` now (`subr.scm`'s,
whose comment already said why it exists).

The `posn_click` group also pins that a stale hscroll is the empty tail
rather than an exception.

## A timer scheduled from the back door waits for a key (2026-11-18)

Not a departure from Emacs, but a property of this front end worth
knowing when driving a terminal editor from the REPL: **a timer added
while the editor is blocked in its read does not shorten that read.** The
command loop computes its wait once, from `timer-next-delay`; a terminal
has no front end loop to wake, so the cooperative REPL runs inside the
read (`read-input-event`'s wake pipe), and when it returns, the read goes
back to `select` with the timeout it was given - which was "block forever"
if no timer existed then.

Measured: in an idle terminal editor, `(run-at-time 0 #f (lambda () ...))`
via `repl -e` leaves the timer due (`timer-next-delay` negative) across
several more REPL calls, and `(timer-check!)` by hand fires them all at
once. **A timer scheduled from the init file is unaffected** - it exists
before the loop computes its first wait - which is the case that matters
for a user's init; a pty run with `(run-at-time 0.5 nil (lambda ()
(message "TIMER-FIRED")))` in `init.scm` shows the message with no
keypress. The Gtk front end is unaffected: its read waits in a Gtk loop
and the timer is a Gtk timeout source.

Fixing it would mean the read returning to the loop when a REPL drain has
run something, so the wait is recomputed - but `#f` from the read already
means end of input when the wait was blocking, so it needs a third answer
or a direct `timer-check!` in the wake path. Named rather than done.

# The comment commands - `newcomment.el` is whole (2026-11-18)

Chris's pick from the "what's next" list, and the file that `comment-indent`
had been sitting in alone since the indentation pass. `newcomment.scm` now
carries the commands and everything under them, in Emacs's file order:

| Emacs | here |
|---|---|
| `comment-string-reverse` `:356` | same |
| `comment-quote-re`/`-nested`/`-nested-default` `:435-488` | same, with `comment-quote-nested-function` as a parameter |
| `comment-set-column` `:799` (C-x ;), `comment-kill` `:822` | same |
| `comment-padright` `:840`, `comment-padleft` `:887` | same |
| `comment-with-narrowing` `:1105` | a `syntax-case` macro |
| `comment-make-bol-ws` `:1067`, `comment-make-extra-lines` `:1075` | same |
| `comment-add` the *function* `:1142` | **`comment-add-count`** - Emacs has both a variable and a function of that name (a Lisp-2), and the variable's accessor keeps the name |
| `comment-region-internal` `:1152` | same |
| `uncomment-region` `:931` + `-default-1` + `-default` | same |
| `comment-region` `:1241` + `-default-1` + `-default` | same |
| `comment-box` `:1350`, `comment-only-p` `:1361`, `comment-or-uncomment-region` `:1369`, `comment-dwim` `:1380` (M-;), `comment-line` `:1583` (C-x C-;) | same |
| `bindings.el:1603-1607` | M-;, C-x ;, C-x C-; bound |

**The bug this shook out, and it was mine**: `comment-forward`'s syntax arm
answers `forward-comment`'s value ("non-nil if it moved"), and the port had
made both arms answer `(= n 0)`. In every programming mode
(`comment-use-syntax` t) `comment-forward` was therefore nil, and
`uncomment-region` raised "Can't find the comment end" for a comment it
could see - in the editor the command loop's guard turned that into a key
that did nothing. `M-x comment-line` on an already-commented line was the
first caller to notice.

## Primitives added for it

* **`prefix-numeric-value`** (`callint.c:805`) in `command.scm` - the C's
  five cases, distinct from `uarg->integer` because this one's default is
  fixed at 1.
* **`mapconcat`** and **`%chars-or-numbers->string`** in `fns.scm`:
  `mapconcat` is `fns.c`'s and its separator is optional (`(2,3)`);
  `concat` now takes lists/vectors of *numbers* as well as characters, as
  the C's `Fstring` does - which is what `mapconcat`'s pieces arrive as.
* **`comment-use-global-state` became `*comment-use-global-state*`**: it is
  a `defvar` that `uncomment-region` `let`-binds, which is the tree's test
  for a parameter. As an accessor over a buffer-local it could not be
  bound.

## Schema traps this pass

* **Guile's `let*` has no bare bindings**: `(let* ((a 1) b) ...)` is
  "source expression failed to match any pattern". Emacs's `let*` with an
  unbound `ce-sanitized` becomes `(ce-sanitized #f)`.
* **A parameter is set by calling it**: three `set!*comment-...-function*`
  spellings compiled as calls to nonexistent procedures (the `!` is part of
  the symbol). The write is `(*comment-quote-nested-function* value)`.
* **`(string c)` where C is a code point is `%char-string`**: `mapconcat`
  over a string hands the function integers, and Scheme's `string` takes
  characters.
* **Elisp's `(< (point) marker)` is `(< (point) (marker-position m))`** -
  markers do no arithmetic here (the fill pass's rule, again).
* **`while` is not Scheme**: two Emacs `while`s became named `let`s.
* **`comment-padright` reads `(match-end 1)` after a match that can fail**;
  the character to duplicate is taken *before* the MULTI test - Emacs's
  matched data survives a failed `string-match` (measured) and this tree's
  does not, and the answer is the same either way.

## Tests

* `newcomment-tests.scm` (new, 13) - every expectation Emacs 31.1's own
  output on the same fixture: `comment-region` (";; aaa"), a numeric ARG,
  `uncomment-region` with and without ARG, `comment-or-uncomment-region`
  both ways, the whole box, `comment-dwim` on a blank line and after code
  (`abc\t\t\t\t;`), `comment-kill`, `comment-set-column`, the padding
  helpers' strings and regexps, `comment-add-count`, and one case in a
  **real `scheme-mode` buffer** - which is `comment-forward`'s syntax arm,
  and which fails with the old port ("Can't find the comment end").
* `tools/pty-check.py` gained **`comment-commands`** (96 checks now): M-x
  `comment-line` comments and, on the same line again, uncomments; `M-;` on
  a blank line inserts `;;`. It fails with the old `comment-forward`
  ("comment-line did not uncomment the line"). `C-x C-;` cannot be driven
  on a terminal: `(event-convert-list '(control ?;))` is 27, the same event
  as ESC - Emacs's own limitation, not this tree's.

## The `completion-window` battery check was a real departure (2026-11-18)

The one check that kept coming back red across full batteries - "C-g left
the list's window behind (3 mode lines, expected 2)" - is not a battery
flake and not the completion code. **The command loop did not redisplay
after reporting an error.** Emacs's `command_loop_1` runs the command in
a condition-case and falls through to the loop's redisplay whatever
happened (`keyboard.c:1637`); ours reported and went straight back to
the read, so a command that raised part-way left the screen showing what
it had drawn. DEPARTURES.md has the section.

The fix is one call - `(guard (ex (else (report-command-error! frame ex)
(redisplay-frames!)))` in `keyboard.scm` - and it was seen failing on the
baseline: with the redisplay reverted, the reproduction probe showed the
stale window in 1 run of 20; with it, 15/15 clean and the check passes
repeatedly.

**The general shape**: a check that fails with a screen from *before* the
key that should have changed it is a redisplay that never ran, not a
timing race. The per-key settle cannot help, because the editor is
quiet - it is idle and wrong. Look for the path that skipped the
redisplay before blaming load.

## The startup hooks, and the *scratch* buffer (2026-11-18)

The two `startup.el` gaps this file kept naming: `before-init-hook` /
`after-init-hook` / `emacs-startup-hook` / `window-setup-hook`, and the
`*scratch*` message and mode. DEPARTURES.md has the C and the measured
placement; this is what the next session needs.

* **The hook placement is measured, not inferred.** With
  `inhibit-startup-screen` non-nil Emacs still runs `emacs-startup-hook`
  and `window-setup-hook` - in `normal-top-level`'s tail, not "never".
  The rule was established with an init file that adds a logging function
  to each hook and a `script -qec emacs -nw` run both ways. This tree's
  `command-line-1` has the splash branch and the else that stands for
  that tail.
* **`before-init-hook`/`after-init-hook` live around the init-file load
  in `load-init`**; `after-init-hook` is *outside* the `catch`, so a
  failing init file still gets it - Emacs's `command-line` runs it after
  `startup--load-user-init-file`'s own catch.
* **The front ends make `*scratch*` before `command-line-1`**, so the
  `:3015` block is what fills it; the `:1723` block gives it
  `initial-major-mode` only if it is still `fundamental-mode`, which is
  why the mode line reads `(Lisp Interaction)` rather than
  `(Fundamental)`.
* `window.scm` gained `*get-scratch-buffer-create-function*` (the
  seam-from-above pattern); `startup.scm` installs it at load. `imports.scm`
  is regenerated - `tools/gen-imports.scm` - or M-:/the REPL/init files
  cannot see the new names.
* `startup-tests.scm` grew two groups (16 tests): the scratch buffer's
  message/mode/unmodified rules, and the hooks' order with a successful
  and a failing init file. `tools/pty-check.py` gained `scratch` (97
  checks now), which is the end-to-end one: with no file argument the
  editor shows the message with `C-x C-f` substituted, the mode line
  says `(Lisp Interaction)`, and an init that inhibits the startup screen
  still leaves the hook log `ew`. Each half was seen failing with its
  wiring stripped.

### The startup pass found a real fontification bug (2026-11-18)

Applying `initial-major-mode` to `*scratch*` - which is what Emacs does -
turned two pty checks red, and the cause is **not** the startup code.
Measured: `(describe-bindings)` takes 12-14 ms in a fresh editor and
~510 ms after any `lisp-interaction-mode`/`emacs-lisp-mode` has *run*
anywhere in the session; flipping modes back does not undo it
(`(14 507 514)` in one editor). The time is in the syntactic fontifying
of the text being inserted into `*Help*`, which makes `describe-bindings`
silent for half a second - longer than the harness's quiet window, which
is why the checks saw a dead command.

Ruled out by measurement: the global `before-change-functions` flush
hook, `%syntax-propertize-done`, the described buffer's mode, and Help's
own state. DEPARTURES.md has the numbers and the first suspects - the
syntax layer's module-level `%gl-state`/per-character propertize check,
where the C keeps its state per buffer. **This is pre-existing**: any
`.scm`/`.el` buffer poisons the session the same way.

The harness now does what this file already says it should: `C-h b` and
`C-h s` say `WAIT` for `Global Bindings`/`which means:` instead of
relying on quiet, and assert the `gave up waiting` marker's absence.

**Next task**: find that module-level state. Everything else in the
startup pass stands (hooks, the message, the mode).

## jit-lock: the fontification stall is fixed (2026-11-18/19)

The bug the startup pass found - `describe-bindings` 510 ms after any
lisp-family mode had run, 13 ms before - is closed at its root.
`schemacs/jit-lock.scm` (the core of `jit-lock.el`),
`fontification-functions` + the redisplay hook in `xdisp.scm`
(`handle_fontified_prop`), and `font-lock`'s `font-lock-support-mode`
wiring: an edit now **marks** the changed text `fontified` nil and the
redisplay fontifies what it draws. Measured with the old harness: 200
line-inserts 95 ms -> 1 ms; `(describe-bindings)` ~510 ms -> 17 ms.
DEPARTURES.md has the full accounting of what is and is not carried.

Things to know before touching it:

* **The redisplay hook is `build-row!`'s first statement** - a row whose
  first position is not `fontified` is fontified before its glyphs are
  built, so the faces are there for the row. It is `xdisp.scm`'s
  `run-fontification-functions`, called with `(+ line-start from)`.
* **`fontification-functions` and `jit-lock-functions` are per-buffer
  list entries, not hook parameters** (a parameter is not per buffer);
  `jit-lock-after-change` is on the one global `after-change-functions`
  list, gated on the buffer's `jit-lock-mode`.
* **The extend-region loop's `(eq funs whole-list)` guard is
  load-bearing**: `font-lock-extend-region-wholelines` always answers
  true, and without the guard the loop restarts forever - the dired
  suite hung on the first run. It is now Emacs's loop shape.
* **Tests that assert faces must call `(font-lock-ensure)` first** -
  font-lock-tests, lisp-mode-tests and dired-mode-tests do, which is
  what Emacs's own callers do with jit-lock. A test that inserts and
  reads a face without it will see the old one and look right, which is
  the trap to keep in mind.
* `font-lock-extend-region-wholelines` is ported after all
  (`syntax-propertize-wholelines` had been there since the syntax
  engine pass); the "not ported" note was stale and is gone.

Not carried and named in `jit-lock.scm`: stealth and deferred
fontification, the antiblink hook, `jit-lock-debug-mode`,
indirect-buffer refusal. (Contextual fontification was carried on
2026-11-19 - see the section at the end of this file; the "not carried"
note this paragraph used to have gave line-by-line fontification as its
reason, which is in fact the reason the sweep is needed.)

## `C-h ?` — help-for-help, and the two bugs under it (2026-11-19)

Chris finished the paren frame by hand; the in-flight note below this
section is kept only for the trap it records. The screen, its dispatch
and `C-h C-h` are in, and getting them to work found two real bugs three
layers apart.

## What landed

* **`help.scm`**: `help--help-screen` (`help-macro.el:105`), its seam
  install, `help-quit` (`help.el:286`), `help--for-help-make-commands`
  (`:365`), `help--for-help-make-sections` (`:384`), the trimmed option
  table, the `make-help-screen` expansion, `help-map`'s `q` and `?`, and
  the flat `C-h ?` / `C-h C-h` bindings (`help.el:62-66`).
* **`keymap.scm`**: `access-keymap` is the C's, with NOINHERIT and
  keymap lists (see DEPARTURES.md); `keymapp` accepts a keymap list;
  `lookup-key` and `keymap-lookup` descend into one; `define-key` passes
  NOINHERIT.
* **`keyboard.scm`**: `read-key-event` **redisplays before it waits** -
  the C's `read_char` does (`keyboard.c:2718-2723`, "Redisplay if no
  pending input"), and without it EVERY nested read drew nothing.
* `tools/pty-check.py`'s **`metahelp`** (98 checks): the screen and its
  substituted keys, `b` dispatching to `describe-bindings`, `C-g`
  restoring the window, `C-h C-h`. `subr-tests` grew four cases for the
  keymap inheritance, each Emacs 31.1's own answer.

## Bug 1: nothing drew between reads

`C-h ?` left the editor's state correct - `*Metahelp*` current, the text
inserted, `(pos-visible-in-window-p (point-max))` false - and the
terminal showing the previous buffer. The minibuffer has always drawn
because it reads through `recursive-edit`, a command loop that
redisplays; `help--help-screen` reads with `read-key-sequence`, which is
`read_key_sequence` and has no redisplay of its own. In GNU Emacs
`read_char` redisplays before it blocks (`keyboard.c:2718-2723`), so
every read does. `read-key-event` now does the same, and it is the only
place that needs to: everything that reads goes through it.

That is a departure **the tree had from the beginning**, not one this
pass introduced: any command that read a key outside the minibuffer
(e.g. the `k` interactive code) would have had a stale screen. It had
simply never been exercised by a command that changes the display and
then reads.

## Bug 2: `b` said "No help command is bound"

`help--help-screen` looks its option up with `(lookup-key local-map
key)`, where `local-map`'s options live in its parent `help-map`
(`(set-keymap-parent local-map helped-map)`). `lookup-key` never asked
the parent: `access-keymap` was written as the C's *noinherit* half
only - correct for `define-key`, wrong for `lookup-key`. Emacs 31.1
measured: a child's `lookup-key` finds the parent's binding; a key only
the parent's prefix defines is reachable through a child that defines
the same prefix; and the answer to "the prefix" when both define it is
a **keymap list** `(keymap CHILD PARENT)`. All three are ported now, and
`define-key` still does not inherit (a parent's command does not stop a
child making its own prefix - measured, no error).

## Guile facts this pass cost

* **`unwind-protect` cannot be used in a library**: `(only (guile)
  unwind-protect)` finds no binding, and a bare `unwind-protect` in a
  library body *compiles* (with a "possibly unbound" warning) and is
  **unbound at runtime**. The tree's spelling is `dynamic-wind` with
  thunks - `save-excursion`/`save-restriction` do the same. The C's
  `unwind-protect` frame is `(dynamic-wind (lambda () #f) body cleanup)`.
* **A pattern variable cannot be spliced into `quasisyntax`**: "reference
  to pattern variable outside syntax form". Build the name with
  `(datum->syntax (syntax fname) (syntax->datum (syntax fname)))` and
  splice that *value*, as `define-minor-mode` splices `mode-id`.
  `syntax-case`, `quasisyntax`, `unsyntax`, `datum->syntax` and
  `syntax->datum` are `(only (guile) ...)` imports; `(scheme base)` has
  none of them.

## The trimmed option table, and why

`help-for-help`'s table (`help.el:405-472`) is carried **less every
entry whose command this tree does not have**, and the help line is
trimmed to `"Type a help option: [bcfkmoqsvw] or ?"` to match. The
omissions are listed by section in `%help-for-help-sections`' comment:
apropos, the whole Manuals section (info), `view-emacs-*` and friends,
`describe-input-method`/`describe-language-environment`, and
`view-lossage` (a keyboard record is not ported). Two sections remain -
Commands/Keys/Functions and the syntax table.

## Departures left standing in `help--help-screen`

* `variable-pitch-mode` is not ported (the option is carried, the branch
  skipped); `iconify-frame`/`handle-switch-frame`/
  `frame-toggle-on-screen-keyboard` do not exist here;
  `vertical-scroll-bar` is in the key list and never arises (no scroll
  bars); `ding` is not ported, so an unbound option reports without a
  bell.
* The C's `(define-key local-map [t] #'undefined)` is **not needed**:
  an unbound key already answers #f from `lookup-key` here, and the
  else branch reports it. (In the C the `t` entry is invisible to that
  same `lookup-key` call too - its third argument is nil, so
  `access_keymap` ignores `t` bindings.)
* The scroll keys call `scroll-up-command`/`scroll-down-command` where
  the C calls the `scroll-up`/`scroll-down` primitives
  (`scroll_command`, `window.c:6975`, is not ported).
* The prompt's page keys are `(kbd "<PageDown>")`/`(kbd "<PageUp>")`
  (the C's spelling), **not** `(kbd "next")` - which reads as the four
  characters n-e-x-t and renders "n e x t" (Emacs answers
  `(key-description (kbd "next"))` = `"n e x t"` too; the mistake was
  mine, found by comparing the prompt against the C line).

## Verified

* `tools/pty-check.py`'s **`metahelp`** (98 checks in the battery):
  the screen and its substituted keys, `b` dispatching to
  `describe-bindings`, `C-g` restoring the window, and `C-h C-h`. The
  dispatch assertion was seen failing with the old `access-keymap` (the
  user's own "No help command is bound to `b'"), and the screen one with
  the read-path redisplay removed.
* `help-tests` 50 (five new, every expected string Emacs 31.1's own
  `substring-no-properties` answer) and `subr-tests` 104 (four new, the
  keymap-inheritance table). All 73 suites pass; the tree compiles with
  no new warnings.
* The full pty battery on this tree: **97/98** in two runs, with a
  *different* single check red each time - `query-replace-quit` and then
  `quoted-insert` - each passing 3/3 when run alone on the same tree.
  Both are the battery's documented load-flake class, and both failure
  screens were the pre-keypress one. (Comment-only change made after
  the last run: `keymap-lookup`'s "too long" note, DEPARTURES.md.)
* One trap paid for in the test file: a `\[NAME]` inside a *Scheme
  string literal* is `invalid character in escape sequence: #\[`, and
  the reader stops there - the suite then runs only the tests above the
  bad form, prints no summary, and exits 1. The suite runner calls that
  "DID NOT RUN", which is the check that catches it.

## `C-h k M-:` — a read that made a character of a meta event (2026-11-19)

Chris, from the editor: `C-h k M-:` answered "Value out of range -1 to
<1114111>: 134217786". The fix is in `read-key-sequence`, and
DEPARTURES.md has the C each half was taken from; in one line each:

* `%read-key-sequence-answer` decided string-versus-vector with "are all
  events integers?" and then called `integer->char`. Emacs's rule is
  `make_event_array` (`alloc.c:3691`): a string only for events below
  0200 after discarding the meta bit. A meta event answers a *vector*
  here, because Emacs's unibyte-string spelling of it (byte 0xBA for
  `M-:`) cannot be carried in a Unicode string - a named departure.
* `%read-key-sequence` did not fold a terminal's ESC prefix into the
  meta event (`read_key_sequence`'s `meta_prefix_char`,
  `keyboard.c:11829`). The command loop already had that state machine
  (`*esc-pending*`); the read `C-h k` and the `k`/`K` codes use did not,
  so `C-h k ESC :` described "ESC is undefined" (measured before the
  fix).
* `characterp`'s comment claimed Emacs answers t for `M-x`; measured,
  it is nil - the modifier bits are above `MAX_CHAR`. That wrong note is
  the likely origin of the "all integers" test.

Tests: `tty-editor-tests`' new `read_key_sequence` group (4) and the pty
battery's new `describe-key-meta` check.

## The help pass, closed: `help-fns--insert-menu-bindings` (2026-11-19)

The last named gap in the help commands is in: `describe-function` now
prints "It can also be invoked from the menu: File → Save", called where
`help-fns.el:636` calls it, with the heading, the remap suffix, the
punctuation test and the `ensure-empty-lines` tail the function had been
missing. DEPARTURES.md has the C and every representation note; the
things worth carrying forward:

* **`where-is-internal` never found a menu sequence.** Keyboard bindings
  are command *values*; a `(menu-item "Save" save-buffer)` answers its
  *symbol* from `get_keyelt`, so both the walk and the shadow check
  compared unlike things and dropped every menu binding. `%where-is-value`
  resolves a symbol naming a command through the command table, and both
  comparisons use it. Measured: `(where-is-internal 'save-buffer)` was
  `([24 19])`, is now `([24 19] [menu-bar file save-buffer])` - Emacs's
  own answer.
* **Emacs's `(string-join SEQ)` separator is `""`** (measured); Guile's
  is `" "`. The push-and-join idiom produced "File  →  Save" until `""`
  was passed explicitly.
* Emacs's `(assq entry (cdr map))` is a hash lookup of the *raw* binding
  here, and the C's `(nth 2 elem)`/`(cadddr elem)` read the raw list's
  cadr/caddr of `(menu-item NAME DEF ...)`. Emacs's `proper-list-p`
  guard becomes the two shapes' own tests, because the old
  `(STRING . SUBMAP)` spelling is improper here (its cdr is a keymap
  record).
* The remap sentences now name the command via
  `help-fns-function-name`: Emacs prints a symbol, this tree's
  remapping answers the binding.
* `char-displayable-p` of `→` is #t here, so the separator is ` → `.
* A minor **order** difference is named in DEPARTURES.md: our menus are
  loaded after every key library, so `where-is-internal` lists a menu
  sequence before a chord where Emacs lists the chord first. Content is
  the same, and `describe-function` splits keys from menus.

Tests: `menu-bar-menus-tests` +2 (9), including the whole sentence from
`describe-function 'save-buffer`, measured on Emacs 31.1. All 73 suites
pass, and the full pty battery on this tree is **99/99**, exit 0 (the
`describe-key-meta` check added with the `C-h k M-:` fix included).

# The read-path coding detector, closed (2026-11-19)

Chris picked "read-path coding detector" from the next-pass list, which
was built on the handoff's claim that `detect_coding` was not ported.
**It was ported after that note was written** - `detect-coding-bytes`
(`coding.scm:1738`), called by `files.scm`'s `coding-system-for-file`,
with a 2026-10-13 test pinning `45 78 135 -> utf-8-unix`. The pass
therefore became: verify it, repair the tool that says so, and fix what
verifying it exposed.

## The mystery, resolved by reading

The 2026-10-06 session stopped because Emacs's `find-file` answered
`utf-8-unix` for `2D 4E 87` while its `detect-coding-region` answered
`raw-text`, and no reading of `detect_coding` seemed to reach utf-8.
The missing step is **`CODING_MODE_LAST_BLOCK`**: `detect_coding_system`
sets it (`coding.c:8743`), `detect_coding` does not, and
`decode_coding_gap` - the file-visit path, `fileio.c:5132` - never sets
it before detection. `detect_coding_utf_8` therefore treats a sequence
cut off by end of file as *inconclusive* (`no_more_source`, the
`mode & CODING_MODE_LAST_BLOCK` test) and accepts it, where the
region API rejects it. Measured here:

| bytes | `find-file` | `detect-coding-region` |
|---|---|---|
| `2D 4E 87` (truncated at EOF) | `utf-8-unix`, trailing byte as a byte character | `raw-text` |
| `2D 4E 87 41` | `japanese-shift-jis-unix` | `japanese-shift-jis` |

and the tree reproduces both (`detect-coding-bytes` passes
`last-block?` false). **The stream detector is a lenient detector, and
Emacs's own inconsistency between the two doors is the behaviour.**

## The crash it exposed

Running `tools/coding-diff.py` on the repaired tool turned up a hard
failure opening the corpus's `shift-jis` file:

    set-auto-mode -> skip-chars-forward -> fetch-char
    Value out of range -1 to <1114111>: 4194178

4194178 is `#x3FFF82`, a byte character. `fetch-char` (`buffer.scm:2488`)
called `integer->char` on the store's code point, and a byte character is
above Guile's `#x10FFFF` on purpose. **Any file whose first line began
with a byte character crashed on visit** - the pty battery never caught it
because its `no-conversion` fixtures start with ASCII (`a\x85b`), so
`skip-chars-forward` never reached the byte. `fetch-char` now goes through
`code-point->char`, the U+FFFD rule every other reader above the store
uses. Regression test: `tty-editor-tests` visits
`#vu8(130 160 130 162)` (the `shift-jis` corpus bytes) and asserts the
coding is `utf-8-unix` (Emacs's answer) and `(char-after 1)` is
`#\xfffd`.

## The tool, which had been lying

`tools/coding-diff.py` reported **0 identical, 19 NEW** on a tree that was
fine, because its schemacs probe could not run at all:

* it imported `(schemacs editor engine)`, deleted in the engine
  dissolution, and called `text-editor-set-modified!`, which no longer
  exists - so it printed nothing and every answer read as `None`;
* it ran `guile` without `-L "$SITE"`, and `keyboard.scm` imports
  `(scheme-utils repl server)` from the user's site directory - the same
  trap the compile recipe documents;
* its `save-buffer` call ran on no buffer (the current one was `#f`), not
  the visited file's;
* `subprocess.run` inherited stdin, so Emacs's "Select coding system"
  prompt waited for ever instead of reading EOF (a 180 s timeout);
* its `shift-jis` KNOWN entry described the detector as unported, which
  was false.

All fixed. Current result: **21 cases, 20 identical, 1 known-different,
0 new** - the one being `iso-2022-jp`, which needs the charset registry
and the ~1400-line ISO-2022 decoder, as the 2026-10-06 reconnaissance
concluded.

## Still open in this area

* `iso-2022-jp` and `iso-2022-7bit` (charset registry first - see
  `charset.scm`, metadata only).
* **iconv's SHIFT-JIS is not Emacs's charset table.** `87 41` decodes in
  Emacs to its internal JIS X 0208 code (measured: 1311849), and iconv
  gives U+FFFD for it. The detector agrees; the codec is the difference.
* `utf-8-emacs` / `emacs-mule` (no iconv equivalent), unibyte buffers,
  `decode-coding-region`.

**The pty battery on this tree: 97/99**, the two failures `completion-ui`
and `quit-after-prefix` - both on the documented load-flake list, and both
**3/3 when run alone** on the same tree.

# The charset registry: maps, conversion, unification (2026-11-19)

The first half of the charset/ISO-2022 pass: the registry now converts
characters, not just describes charsets. `charset.c`'s map machinery,
the four methods, and `unify-charset` are ported; the map data ships in
the tree; and the conversion is verified against Emacs on every charset.

## What landed

* **`schemacs/etc/charsets/`** - Emacs 31.1's 131 generated `.map` files
  and its README, 3.1 MB. Emacs does not keep them in git either: its
  `admin/charsets/Makefile` generates them from the glibc charmaps at
  build time and installs them to `etc/charsets`. `*charset-map-path*`
  defaults to this tree's copy, found on the load path (absolute, so
  `--chdir` cannot break it later) - Emacs's default is its install
  directory; named departure.
* **The registry's conversion layer** in `charset.scm`, in `charset.c`'s
  order: `CODE_POINT_TO_INDEX`/`INDEX_TO_CODE_POINT`, the 190-byte
  fast-map, `load_charset_map_from_file` (the `read_hex` parser, `#`
  comments, `0xA-0xB` ranges), `load_charset_map`'s control flags 0/1/2,
  `load_charset`, `decode_char`/`encode_char`, and the four methods -
  MAP, OFFSET, SUBSET and SUPERSET (the last two added after the first
  data made `gb18030` crash).
* **`unify-charset`** (`charset.c:1318`), `maybe_unify_char`, the global
  `*char-unify-table*`, and the unified arms of decode/encode. Without
  it `(decode-char 'japanese-jisx0208 #x2121)` answers 0x140000 (the
  internal code) where Emacs answers 12288 (U+3000) - which is what
  ISO-2022 text must become in a buffer.
* **The data section re-emitted from Emacs 31.1 with the full
  attributes.** The first transcription had kept only the code space,
  ISO final char, and some offsets/maps; `:subset`, `:superset`,
  `:min-code`/`:max-code` (32-bit values as `(HI . LO)` conses) and
  `:ascii-compatible-p` were missing, so `gb18030` (a superset) was
  defined as an offset charset with a 32-bit code space and crashed the
  fast-map; the `latin-iso8859-*` family was similarly wrong. **A
  transcription that drops attributes is not a subset of Emacs's
  registry - it is a different registry.**
* `charset-tests` grew a `conversion` group (Emacs 31.1's own answers
  for a unified charset, a subset, a superset, the ASCII shortcut, an
  offset charset, the C-defined `emacs` charset's max-code, and the two
  unmapped cases).

## How it was verified

A differential over **every charset** in the registry, ten sampled code
points each (the ends included): 2148 `(decode-char ...)` answers and
1812 `(encode-char ...)` answers, generated by a running Emacs and
compared one for one - **zero differences**. That found the two bugs
above and the ASCII shortcut (`DECODE_CHAR`/`ENCODE_CHAR` answer an
ASCII character through an ASCII-compatible charset before the map is
consulted; MIK's map starts at 0x20, so codes 0 and 21 would otherwise
be "unmapped").

## Two placements, both named

* The 27 `(unify-charset 'x)` calls at the end of `charset.scm` are
  `mule-conf.el`'s list; that file is not ported and the attribute each
  call needs (`:unify-map`) travels with the charset data, so the calls
  live beside it.
* `emacs` is one of five charsets the **C** defines (`init_charset_once`)
  rather than Lisp; its `:max-code` is `MAX_5_BYTE_CHAR`, a value its
  plist does not carry, so it is written into the data by hand and the
  test pins it.

## What remains for ISO-2022 - corrected, and deferred (2026-11-19)

The registry is complete; the ISO-2022 codec is **not written**, and the
"~1400 lines" above was `coding.c` alone. Reading the C found three
subsystems this tree does not have: `char_charset` with
`Vcharset_ordered_list` (the encoder's charset chooser), composition
(the `DECODE_COMPOSITION_*` state machine plus `composition.c`; text is
the same without it, the grouping property is what is missing), and
charset annotations (the `charset` text property the encoder reads back
to preserve a file's designations). Plus the coding-system attributes,
`setup_iso_safe_charsets` and `iso_code_class`.

**Chris's decision, 2026-11-19: defer ISO-2022 and implement the Gtk
tab bar instead.** DEPARTURES.md has the full accounting and the three
scope options for when it is taken up. Nothing of the codec exists in
the tree - there is no half-built ISO-2022 path.

# Contextual fontification is carried (2026-11-19)

Chris: *"why is this not carried?"*, about `jit-lock-contextually`,
which had been carried as a defcustom with the note "fontification is
line-by-line here". **The note was a rationalization with its reason
backwards**: fontification is invalidated lazily per change, and a line
already on screen keeps its `fontified` property - so a syntactic change
above it (an opened string, an opened comment) leaves its old faces
showing for ever. The sweep below is precisely the mechanism that undoes
that, and it is what `jit-lock-contextually` switches.

What landed, all of it in `jit-lock.scm` and in `jit-lock.el`'s order:
`jit-lock-contextually` (the reader over the buffer-local, as Emacs's
`setq-local` in `jit-lock-register` makes it), `jit-lock-context-
unfontify-pos`, `jit-lock-context-timer`, `jit-lock-context--update`,
`jit-lock-context-fontify` (`jit-lock.el:636`), the on branch that arms
the idle timer and seats the position at `point-max`
(`:258-265`), the off branch that cancels it only when no buffer on
`(buffer-list)` is still using it (`:286-302`), `jit-lock-register`'s
contextual upgrade (`:338`), and `jit-lock-after-change`'s
`(min pos jit-lock-start)` (`:701-708`, against the *extended* start
and outside `with-silent-modifications`). The defcustom now carries
Emacs's own docstring.

Two things to know before touching it:

* **`font-lock` decides which buffers get the sweep.** It registers
  with `(not font-lock-keywords-only)` (`font-lock.el`, the tree's
  `font-lock.scm:1574`), so a mode with a syntax table - every
  programming mode - is swept and a keywords-only mode is not, which is
  Emacs's `syntax-driven` default doing its job. If the sweep seems
  not to run, check that first.
* **Tests need a `get-buffer-create` buffer.** `jit-lock-context-fontify`
  walks `(buffer-list)`, as the C's `dolist` does, and an
  `allocate-buffer` buffer is not on that list; the group is
  `schemacs_editor_jit_lock_context` in `jit-lock-tests.scm`.

Still not carried, now without the wrong reason: the antiblink grace
timer (`jit-lock-antiblink-grace`), stealth and deferred fontification,
and the `jit-lock-defer-multiline` walk-back. DEPARTURES.md has the C
line each is taken from, and each is unobservable here except the
antiblink blink while typing an unterminated string.

# The Gtk tab bar's right-click, and the button decode under it
# (2026-11-19)

Chris: *"in real emacs I can right click a tab and a menu pops up, we
don't have that."* Right - and the cause was one layer below the tab
bar: **the Gtk front end decoded every mouse button as button 1**, so a
right-click arrived as `down-mouse-1` and the tab-bar context menu
command (`tab-bar-mouse-context-menu`, bound to `[tab-bar
down-mouse-3]`) could never run. Emacs names the symbol from the
button number (`make_lispy_event` -> `modify_event_symbol`,
`keyboard.c:6760`: `down-mouse-N`, `mouse-N`, `drag-mouse-N`). Fixed in
`pgtk.scm` with `event:get-button` and `pgtk-mouse-button-symbol`;
`pgtk-tests`' `schemacs_pgtk_mouse_buttons` group pins the naming for
buttons 1, 2 and 3. A real Gdk button event cannot be synthesized here,
so the getter half needs a human click; the library loading proves the
import.

**And the thing that started this question was a false note.** Three
source comments and this file said GNU Emacs's Gtk build gives the tab
bar a widget of its own. It does not: `gtkutil.c`/`xmenu.c` build only
the menu bar's widget, the redisplay draws the tab bar into
`f->tab_bar_window` below it, and `pgtkterm.c` hit-tests that window -
the same architecture as our in-text-area row. The claim is corrected
in `frame.scm`, `xdisp.scm`, `tab-bar.scm` and above in this file. The
real remaining difference is the window *object* (Emacs has a
`tab_bar_window`; a click's `posn-window` here is the frame), not the
drawing.

So there is no "Gtk tabs" work of that kind to do. What is genuinely
missing on the bar, now named: `double-`/`triple-mouse-N` (a click
clock), wheel events (Gdk `scroll-event` is a different event type),
and - for the terminal - mouse reporting at all, which `term.scm`
already names.

## The rest of the tab context menus (2026-11-19)

The button decode was half of it. Two more departures in the popup path
had to be fixed before a menu would appear, and both are in the C:

* `popup-menu-normalize-position` (menu-bar.scm) must convert a
  **window** posn to `((X Y) WINDOW)` (`posnp`), and must *not* convert
  a frame posn - which is what a tab-bar click's posn is.
* `x_popup_menu_1`'s decode (menu.scm) must treat a position whose
  second element is `tab-bar` as "the current mouse position"
  (`menu.c:1135`), must fall back to the current position when x/y are
  nil (`(menu-bar)` positions), and must read the `((X Y) WINDOW)` form
  as a *list*, not a dotted pair (`y = Fcar (XCDR (tem))`).

Live proof on Gtk: both context-menu commands now block in the Gtk menu
loop with the menu up. Unit tests: the two `*_context_menu` groups in
`tab-bar-tests`/`tab-line-tests`. If a tab context menu ever silently
does nothing again, check those three decode rules first, then whether
the front end is reporting the button number.

## The rest of the tab context menus, part 2 (2026-11-19)

The menus opened, but their title and items exposed two more
departures, and one of them had been in the tree since window states
were ported:

* **`split-window` had never grown Emacs's SIDE and PIXELWISE**
  (`window.el:2833`). `split-window-no-error` translated SIDE to the
  old `HORIZONTAL` boolean and dropped PIXELWISE, which is why no
  in-tree caller noticed. `window--state-put-1` splits with *pixel*
  sizes, so every put of an internally-split state raised
  wrong-number-of-arguments inside the guard, answered #f, and left a
  #f window that `window--state-put-2` then used - the Duplicate
  menu item's "expecting struct: #f". The port is the whole thing:
  SIDE (`below`/`above`/`left`/`right`, `up`/`down`, any other
  non-nil = `right`, which keeps the old boolean callers working),
  the first-share placement for `above`/`left` (sizes do not swap -
  the tests caught that), child order, and pixelwise.
* **`x_popup_menu_1`'s `hide`-prompt rule** (`menu.c:1305`,
  USE_GTK/NS): a keymap prompt whose first character carries `hide` is
  not a title on a window system, which is what the tab context menus'
  `(propertize "Context Menu" 'hide t)` is for. The Gtk popup draws a
  title as a disabled item, hence the stray "Context Menu" line.

Detach's `frame-live-p` error was collateral of a failed Duplicate in
the same session; a clean editor detaches correctly. Still named: the
tab commands' optional arities (Emacs `&optional`, ours required) -
the menu and interactive paths pass every argument, so nothing
reported hits it.

## The tab bar across a resize (2026-11-19)

`tab-bar-auto-width` sizes the tabs from `frame-inner-width`, so a frame
resize must rebuild them. It did not: `update-tab-bar` is gated on
`update-mode-lines?` (Emacs's flag) and `resize-frame-windows!` never set
it, so the bar drew from stale items while `tab-bar--event-to-item`
recomputed them at click time - wide bar, narrow hit test, right-click on
tab 2 answered "New tab". Fixed in `resize-frame-windows!` beside the
window-change flag. Live check: resizing a Gtk window 80 -> 26 columns
changed the tab caption 32 -> 20 chars.

For tests: `render!` re-derives the frame size from the test display's
fixed 80x24 screen and undoes a `change-frame-size`; call
`update-tab-bar` directly when testing that path.

## HiDPI: the Gtk surface is device-resolution now (2026-11-19)

Chris: *"why does schemacs look blurry?... real emacs look sharp."* The
Gtk front end painted a logical-pixel image surface 1:1 into Gtk's
device-scaled context, so on this machine (scale factor 2; Hyprland
outputs at 1.25/1.6) everything was upscaled 2x. Now:

* the surface is `allocation x scale` device pixels and its drawing
  context is `cairo-scale`d by the factor, so all renderer coordinates
  stay logical and glyphs rasterize at device resolution;
* `pgtk-present!` scales the Gtk context by `1/scale` before the blit,
  making it one source pixel per device pixel;
* `gtk_widget_get_scale_factor` is asked through `dynamic-func` each
  redisplay and the surface is remade when it changes (moving between
  outputs).

Record change: `<pgtk-display>` has a `scale` slot - clear
`~/.cache/guile/ccache` before trusting a test. A display with no
widget (a test's) is scale 1, so the pixel tests are unchanged. A/B
verified from a `grim` screen capture: crisp next to the old code's
soft text.

# The tool bar — Gtk's own widget, Emacs's items (2026-11-19)

Chris: *"implement the tool bar. Do it the same way as emacs. Use the
same icons."* Then, when the first recon said Emacs's Gtk build had no
tool-bar widget: *"Really it's not a native widget? Does gtk not have a
suitable widget?"* **That recon was wrong**, and the correction is the
whole shape of this pass: `gtkutil.c:5524` `xg_create_tool_bar` creates
a real `GtkToolbar` ("emacs-toolbar", `GTK_TOOLBAR_ICONS`, oriented by
`tool-bar-position`, `size-allocate` -> `tb_size_cb`). The glyph tool
bar in `xdisp.c` is `#ifndef HAVE_EXT_TOOL_BAR`. So the port is the
same split as the menu bar: `keyboard.c`'s items, `tool-bar.el`'s
Lisp, and GTK's widget in `pgtk.scm`. A terminal has no tool bar in a
Gtk build - `emacs -nw` has none either - and neither does ours.

## Where it is

- `schemacs/tool-bar.scm` - `tool-bar.el`: `tool-bar-mode`
  (`define-minor-mode`, `:global t`, `:init-value t`), `tool-bar-map`,
  the cache-built keymap, `tool-bar-add-item`/`-from-menu` and their
  local variants, `tool-bar-setup`, `tool-bar-position` (a
  `define-custom` whose `:set` calls `modify-all-frames-parameters`),
  `tool-bar-always-show-default`, `toggle-tool-bar-mode-from-frame`.
- `schemacs/image.scm` - `find-image`, `image-search-load-path`,
  `image-property`, `create-image`, `image-type(-available-p)`,
  `image-mask-p`, `display-images-p`, `*image-load-path*`. No
  `image.c`: the toolkit loads the file, so the answer is the spec, not
  an image struct.
- `schemacs/keyboard.scm` - `tool-bar-items`,
  `parse-tool-bar-item`, the twelve `TOOL_BAR_ITEM_*` slot constants,
  `tool-bar-max-label-size`.
- `schemacs/xdisp.scm` - `update-tool-bar`, the two seams
  (`*tool-bar-items-function*`, `*tool-bar-keymap-function*`),
  `tool-bar-style` and `tool-bar-get-system-style`.
- `schemacs/frame.scm` - `f->tool_bar_items` /
  `f->n_tool_bar_items` (the frame's vector and its slot count),
  `%frame-tool-bar-lines`, `*tool-bar-lines-default-function*` (the
  frame-creation default `pgtkfns.c:1532` reads from the mode
  variable), `modify-all-frames-parameters`.
- `schemacs/ui/gtk/pgtk.scm` - the tool bar section: `pgtk-toolbar`
  and its slots, `pgtk-set-frame-toolbar` (called from
  `flush-display!`, after the menu bar), `pgtk-ensure-toolbar!`
  (`xg_create_tool_bar` + `xg_pack_tool_bar`), `pgtk-fill-toolbar!`
  (`update_frame_tool_bar`'s loop), `pgtk-make-tool-item`
  (`xg_make_tool_item`), `pgtk-tool-bar-selection!`
  (`xg_tool_bar_callback`), `pgtk-grow-by-toolbar!` (`tb_size_cb`),
  `pgtk-icon-from-theme` (`find_icon_from_name`).
- `schemacs/ui/gtk/pgtk-win.scm` (new) - `term/pgtk-win.el`/`x-win.el`'s
  tool bar icon map: `x-gtk-stock-map` (all of `x-win.el:1377`),
  `icon-map-list`, `x-gtk-stock-cache` and `x-gtk-map-stock`.
- `test/ui/gtk/pgtk-win-test.scm` (10) is in
  `tools/run-suites.py`.
- `schemacs/files.scm` / `menu-bar.scm` / `dired.scm` -
  `find-file-read-args`, `find-file-existing`, `menu-find-file-existing`
  and `dired-from-menubar`, so the File menu and the Open/Directory
  buttons name the commands Emacs names.
- `schemacs/etc/images/` - Emacs's own XPMs for the twelve items,
  copied from its `etc/images`. GdkPixbuf reads XPM natively (measured);
  `find-image` resolves them through `image-load-path`, whose default is
  found on the load path exactly as `splash.txt` is.
- `test/tool-bar-test.scm` (31) is in `tools/run-suites.py`.

## The icons are the theme's, not the XPMs

This was the user's first question about the finished bar: *"why are the
icons different to real emacs?"* The answer is in `gtkutil.c:5904` -
`update_frame_tool_bar` maps each image's file name through
`x-gtk-map-stock` and draws `gtk_image_new_from_icon_name` when the
theme has the mapped name; the bundled XPM is only the fallback. So
real Emacs's bar shows the desktop's `document-new`, `document-open`,
`edit-undo`, and ours showed the Gtk2-era bitmaps. Ported in
`pgtk-win.scm`, used by `pgtk-icon-from-theme`; verified live that the
first button's image answers `(image:get-icon-name ...)` =
`"document-new"`.

Two guile-gi facts it cost: `gtk_image_set_from_icon_name` is generated
as a generic that *cannot* dispatch the enum wrapper
`(toolbar:get-icon-size tb)` returns (symbol->enum or the wrapper both
fail with "No applicable method"), while the constructor
`image:new-from-icon-name` takes the enum's **integer**
(`(slot-ref wrapper 'value)`, `GTK_ICON_SIZE_LARGE_TOOLBAR` = 3) and
works. And `icon-theme:has-icon` is spelled `icon-theme:has-icon?`.

**The bar is coloured with the mode line's colours**, like the menu
bar: `pgtk-ensure-toolbar!` adds the `schemacs-toolbar` class and the
menu bar's CSS provider to its style context, and
`pgtk-menubar-css-text` carries rules for it (background, buttons, a
hover that inverts, separators). `pgtk-set-frame-toolbar` runs
`pgtk-theme-menubar!` itself so the colours follow a theme change even
with `menu-bar-mode` off. This is a deliberate departure from Emacs
(whose toolbar is theme-coloured), asked for.

## How a click runs

A `GtkButton` "clicked" calls `pgtk-tool-bar-selection!`, which queues
two keys - the symbol `tool-bar` and the item's key - tagged
`tool-bar-event` (handled beside `menu-bar-event` in the queue decode).
The command loop's modal lookup finds `[tool-bar]` (whose binding
`tool-bar-make-keymap` keeps set to the *built* map) and then the item's
key in it. This is Emacs's two-step: the C's `TOOL_BAR_EVENT` is
`(KEY (FRAME tool-bar))` and `read_key_sequence` expands it into the
same fake prefix. Verified live by emitting a probe item's `clicked`
and reading `"TB-CLICK-OK"` from the echo area.

## Two bugs that each looked like something else

1. **A 99%-CPU "Gtk hang" was a Scheme loop.** `pgtk-fill-toolbar!`'s
   recursive call sat *outside* the `when`, so it spun after the last
   item. Debug prints looked absent because `current-error-port` was
   block-buffered: `(setvbuf (current-error-port) 'none)` must come
   first in any front-end trace. A `container:get-children` probe from
   the *user* module raised "Too few in arguments" - guile-gi's
   generics resolve per module, so a REPL probe of a Gtk generic does
   not tell you what `pgtk.scm` can call.
2. **9.5 ms per redisplay** was `widget:get-allocated-height` on the
   toolbar, asked every redisplay to decide whether to grow the
   window. Emacs's `tb_size_cb` is the mechanism: the toolbar's own
   `size-allocate` calls `pgtk-grow-by-toolbar!`, and the explicit call
   runs only when the bar was built or shown. Idle CPU went from ~25%
   (one blink per 0.5 s) back to 0.

## Gotchas worth carrying

- **`image-property`, not `plist-get`, on an image object.** An image
  spec is `(image :type ... :file ...)`; `(plist-get image :type)`
  treats the leading `image` symbol as a key and reads every later
  property one slot off (it cost an afternoon of "find-image works but
  find-image returns #f").
- **`define-custom`'s `:initialize` takes the procedure, not its
  name** - `:initialize custom-initialize-default`, as `tab-line.scm`
  writes it. Written quoted it is applied and raises "Wrong type to
  apply".
- **Guile's `hashq` is `(hashq obj size)`** and size must be >= 1; use
  `object-address` for identity.
- **`ps -o pcpu` is a lifetime average** and read 99% for an editor
  that was actually idle; sample `time` twice.
- **A multi-line debug print removed by line-filter leaves its
  continuation lines behind**, which is how a paren imbalance and a
  stray `(pgtk-allocation d))` appeared here. Splice whole forms,
  verified by the reader, and re-check with the file-wide compile after
  such a cleanup.
- `emacs -nw` on a Gtk build has no tool bar; calling `tool-bar-setup`
  on the terminal front end is what Emacs does and draws nothing.

# The graphical file dialog (2026-11-19)

Chris: *"can you change it so open from the menu or toolbar has a
graphical open dialog, like real emacs"*. Menu File→Open and the tool
bar's Open button now raise Gtk's own `GtkFileChooserDialog`;
`C-x C-f` and the other typed commands still use the minibuffer,
exactly as in Emacs.

## What decides it

`read-file-name` calls `next-read-file-uses-dialog-p` (`fileio.c:6574`),
which is true when **the last nonmenu event is nil or a cons** and
`use-dialog-box`/`use-file-dialog` are on and the frame is a window
system's. A typed key is recorded as itself (not a cons); a mouse event
or a menu selection is recorded as a cons. That is the whole "menu
commands get dialogs" rule - there is no flag that says "came from a
menu".

To make it work here, three things landed that the tree did not have:

- **`last-nonmenu-event`** (`keyboard.scm`'s `*last-nonmenu-event*`,
  with `record-nonmenu-event!`). **Every path that hands a key to the
  command loop must record**: `read-key-event`, `dispatch-input-event`,
  and the Gtk front end's `pgtk-drain-queue!` - the last is easy to
  forget because that front end's outermost loop does not read.
- **`use-dialog-box` / `use-file-dialog`** in `fns.scm` - note the pair
  is deliberately a parameter and a plain variable (Emacs `let`-binds
  only the first).
- **`x-file-dialog`**, a `dispnew.scm` generic whose Gtk method is
  `pgtk.scm`'s. It builds the chooser (`pgtk-build-file-dialog`), runs
  it in a nested Gtk main loop (`pgtk-get-file-name`), and signals quit
  on Cancel as the C does.

## Things to know before touching it

* **The chooser's action is chosen by the caller's booleans**: an
  existing file (`mustmatch`) is `open`, a directory (`only-dir`, which
  is `(eq? predicate file-directory-p)`) is `select-folder`, anything
  else is `save`. `read-directory-name` now passes `file-directory-p`
  as `read-file-name`'s sixth argument, which closed the old "PREDICATE
  is not carried" departure of the `D` interactive code.
* **`dialog-mustmatch` is nil for `confirm` and
  `confirm-after-completion`** - so a File→Visit New File… dialog can
  create a file; a literal `t` is the only "must exist" for a dialog.
* **The file completion table now applies its predicate to each
  candidate expanded against the directory** (as
  `completion-file-name-table` does), which is what makes
  `read-directory-name` complete only directories.
* **`(make <GtkFileChooserDialog>)` is the constructor**: the typelib
  has no `file-chooser-dialog-new` because the C one is variadic. Set
  action and buttons afterwards. `file-chooser:get-show-hidden?` and
  `toggle-button:get-active?` carry the `?` suffix - the tree's
  predicate-naming rule, not a typo.
* **The wrapper properties are the C functions' names with a `?`** in
  this guile-gi: `file-chooser:set-filename?`, `set-current-folder?`;
  `set-action`, `set-current-name`, `set-local-only`,
  `set-extra-widget`, `dialog:add-button` and `dialog:response` are
  plain.
* Emacs timers run during the dialog without any extra machinery: the
  tree arms them as Gtk timeout sources (`pgtk-arm-timer!`), and a
  nested Gtk loop dispatches them. That is the reason `xg_dialog_run`
  exists rather than `gtk_dialog_run`, ported as it stands.
* **Verification that matters**: unit tests use a stub chooser on a
  `<test-display>` (`tty-editor-tests.scm`'s `file_dialog` group);
  the Gtk widget itself needs a display, so the live check was done on
  a broadway editor - the dialog opened, took a name, answered OK, and
  `read-file-name` returned it; and the real menu path was driven by
  enqueuing `(menu-bar-event . menu-bar)`, `(file)`, `(open-file)`.
  The last one is also the regression test for
  `record-nonmenu-event!` in the drain: without it the menu command
  would have taken the minibuffer and blocked instead of opening the
  dialog.

## The dialog's crash: two guile-gi ownership bugs (2026-11-19)

Chris clicked tool bar Open/Cancel a few times and the Gtk editor core
dumped. Two separate ownership mistakes, both now fixed and both in
DEPARTURES.md with the measured evidence:

1. **A dialog's widget proxies must be held for the display's life**
   (`pgtk-hold-widget!`), like the menu bar's and the tool bar's: the
   dialog is destroyed after each use, and collecting a proxy of a
   destroyed widget makes guile-gi release its toggle reference and
   then unref the object it just released - the
   `g_object_unref: G_IS_OBJECT` criticals.
2. **Never call `main-loop:unref` on a loop guile-gi created.** The
   proxy owns that reference and releases it when collected; the extra
   unref in the dialog (and in `pgtk-wait!`'s nested-loop path, its
   first instance) freed the loop early and the finalizer then
   unref'd freed memory - `g_main_loop_unref: ref_count > 0` criticals
   and eventually a SIGSEGV inside `g_malloc` while the next dialog's
   template was built. Measured: five open/OK and three open/Cancel
   cycles, each followed by `(gc)`, now run with zero criticals and the
   editor alive.

The `gtk_tree_drag_source_drag_data_delete` assertion the same session
printed is GTK3's own file-chooser internals (a drag source on its tree
view) and is a critical line, not a crash - do not chase it as ours.

Also in this pass: `dired-read-dir-and-switches` now takes the C's two
arms (`read-directory-name` when a dialog is used, `read-file-name` for
a typed `C-x d` so wildcard completion still works), and the dialog
group in `tty-editor-tests.scm` pins it with the stub chooser.

## The isearch tool bar, and the buffer-local `tool-bar-map` (2026-11-19)

Chris: *"hitting search in real emacs brings up a sub toolbar"*. It is
`isearch-mode`'s `(setq-local tool-bar-map isearch-tool-bar-map)`, and
the blocker was that this tree read only the *global* `tool-bar-map`.
Now:

- **`%tool-bar-map` is buffer-local-aware** (`local-variable-p` +
  `buffer-local-value`, new in `buffer.scm` from `data.c:2416`), so a
  buffer's own map wins. The isearch loop sets it on entry and
  restores/removes it in a `dynamic-wind` after-thunk, as
  `isearch-done` does.
- **`isearch-tool-bar-map`** lives in `isearch.scm`: Repeat backward,
  Repeat forward, Abort, Finish, Undo, Help. Omitted: Show hits
  (`occur` not ported) and Replace (`isearch-query-replace` not
  ported). `:visible`/`:filter` are not carried - the menu evaluator
  runs in the current module, not isearch's.
- **A click is `tool-bar` plus the item's key**, and the search's own
  read pairs them (it has no modal lookup); each key maps to the code
  of the key it stands for. This is pinned by the tty isearch tests
  with a scripted `tool-bar` event.
- **`tool-bar--image-expression` moved to `image.scm`** to break the
  cycle (`tool-bar.scm` imports isearch for `isearch-forward`).
  **Do not remove the `face-attribute`/`display-color-p`/
  `*display-color-cells*` import from `tool-bar.scm`** - its own code
  no longer uses them, but the image *forms* do, and without them every
  icon silently disappears (the evaluator's guard answers nil). That
  happened; `tool-bar-tests.scm` now pins it.
- **A stale editor will not show any of this.** Several `se` instances
  from a test session can hold the same `schemacs` socket; a probe that
  connects to one of *those* runs old code and reports nonsense. Use
  `SCHEMACS_INSTANCE=name` for probes and kill test editors afterwards.

# The tool bar's labels, its greying, and the Replace button (2026-11-20)

Chris's four questions about the Gtk tool bar - *6 icons where Emacs has
7, the 4th wrong, why Emacs's have labels and ours never do, and why
Emacs greys Save/Undo when they do not apply* - and what each turned out
to be. DEPARTURES.md has the C for every rule; this is what the next
session needs.

## The labels: the desktop's `toolbar-style`, read through GSettings

`tool-bar-get-system-style` had no front-end method, so ours always fell
back to `image`. It has Emacs's rule now (`tool-bar-style` if set, else
`*tool-bar-system-style-function*`, else `image`), Gtk answers from
GSettings `org.gnome.desktop.interface`/`toolbar-style` (`xsettings.c`)
- this desktop says `both-horiz` - and `xg_make_tool_item` is ported
whole: horizontal box for `both-horiz`, image before or after the label
per `text-image-horiz`, the label suppressed for `:vert-only` items when
horizontal. `:label`/caption derivation was already right in
`parse-tool-bar-item`; nothing to change there.

**Gio's typelib is loaded in `pgtk-names.scm`** - Gtk's surface does not
export GSettings. The schema key is checked before `settings:new`,
because `g_settings_new` *aborts* on an uninstalled schema, and the
`changed` signal does what `dynamic-setting.el` does
(`force-mode-line-update t`). The style is **cached** (Emacs's
`current_tool_bar_style`): the read is a ~3.5 ms guile-gi crossing and
the bar is rebuilt on every keystroke that forces the mode line, which
a search does on every key; the `changed` handler refreshes the cache,
and the bar's up-to-date test compares the style beside the items
(`gtkutil.c:5919`), so a live `toolbar-style` change refills the bar -
the cached value is `(STYLE . ITEMS)`.

## The 4th button: publish the search's state

`:visible` was already honoured by both parsers; what was missing was
the state and the form. `isearch-tool-bar-map` now has Emacs's
`':visible '(not (string-equal isearch-string ""))` on Finish, and the
search loop publishes `isearch-string`, `isearch-success`,
`isearch-case-fold-search`, `isearch-other-end`, `isearch-regexp` each
iteration and calls `force-mode-line-update` (Emacs's `isearch-update`
line - what makes the bar re-parse). `string-equal` is `fns.c`'s and is
ported.

**`isearch-forward` the *variable* is deliberately not carried**: it
collides with the command of that name in a Lisp-1, and nothing in the
query-replace path reads it. (The `comment-add`/`tab-bar-separator`
collision class.)

Live, on Gtk: `("888" typed)` yields
`(repeat-backward repeat-forward Abort Finish Undo Replace Help)` and
deleting it yields `(... Abort Undo Replace Help)` - Emacs's layout.

## The greying: the *menu items'* forms, because the bar copies them

`tool-bar-add-item-from-menu` appends the menu item's properties, so
Save/Undo/Paste grey out because their `menu-bar-edit-menu` entries do.
Undo and Redo now carry Emacs 31's own tests, over
**`undo-equiv-table`/`undo--last-change-was-undo-p`** - ported, filled
where Emacs fills it - `*pending-undo-list*` uses the `t` sentinel at
exhaustion, and `undo-redo` has the C's three assignments. **The
`*last-change-was-undo*` flag is deleted**; it was the stand-in for the
table and the command loop no longer clears it. Paste tests
`(pair? (*kill-ring*))` beside the clipboard.

**`selection-exists?` on Gtk is non-blocking now** - GDK's owner query
through FFI, as `pgtkselect.c:1779` - which also removed a wait on
another program's response time from the redisplay path. Measured: a
real Emacs 31.1 on this desktop answers nil for CLIPBOARD even with
`wl-copy` owning it (GDK Wayland does not report owners), so Paste is
enabled by the kill ring alone there too.

## The Replace button: `isearch-query-replace`, and where it had to live

Emacs's command is `isearch.el`'s and lives in **`replace.scm`** here: it
needs `perform-replace`/`query-replace-read-to`, and `replace.scm`
imports `isearch.scm` - the mirror order is a cycle. The search's loop
calls it *after* its `dynamic-wind`: the button's branch exits through
`isearch-done` (factored out of the RET branch - same code, named) and
answers a thunk; `isearch` runs the thunk once the wind has put the
buffer's own bar back. `isearch-done` must not clear
`isearch-other-end` - Emacs's does not and the command reads it.

**The 7th button is `isearch-occur`, which needs `occur`** - ~1500 lines
of replace.el (`occur-engine`, `occur-mode`, `occur-edit-mode`, the
target text properties) - and is not ported. That is the whole of the
6-vs-7 difference now.

## `force-mode-line-update` was setting the strong flag

The search calls it per key (Emacs's `isearch-update` line) and the pty
check `isearch-multiline` went red: the match highlight vanished. Its
body set *both* `windows-or-buffers-changed?` and `update-mode-lines?`,
where `buffer.c:1543` sets only `update_mode_lines`; here the strong
flag is read by `render!` as "the frame is garbaged", so every search
key threw the frame away mid-highlight. Fixed in the function (the
weak flag only). Nothing had called it during a redisplay-heavy command
before, which is why it took a pty check to see.

## Traps this pass paid for

- **The item forms are evaluated in the ambient module** (guile-user,
  given the editor's names by `open-user-environment!`). A test module
  has to import `string-equal`/`isearch-string` for them to resolve, or
  `menu-item-eval-property`'s guard answers nil and the item silently
  disappears. A user `imports.scm` that omits the editor does the same
  to their menus - named in DEPARTURES.md, not fixed.
- **A property-plist walk starts after the command, one element at a
  time.** `(cddr item)` is `(CMD :enable FORM ...)`: stepping TWO skips
  past `:enable`. My first test helper returned #f and every "the
  greying is broken" conclusion that followed was the helper.
- **`set!` on an imported variable works and is seen by `eval`** - the
  probe that proved it is three lines - but the *first* failure was
  `string-equal` unbound, not the set!.
- **You cannot inject a key into a running Gtk editor through the REPL
  as an integer**: the queue holds `(key-event . RAW)` items the signal
  handlers build, `pgtk-enqueue!` expects a GdkEvent, and pushing raw
  integers into `pgtk-queue` plus `(pgtk-wake!)` worked for the isearch
  read (888, tool-bar clicks) but not for the minibuffer read that
  followed - the state to use is the *unit tests* and the real keyboard.
  The valuable half: `(frame-tool-bar-items f)` read from the session is
  how the bar's items were verified live, and `pgtk-enqueue!` with
  `(cons 'tool-bar-event key)` is how a button click can be simulated.
- **A running editor keeps its code**: every fix here needs a restart
  before Chris can see it.

## Tests

- `tool-bar-tests.scm` 34 -> 35: the search bar's keys (now 7), Finish
  present/absent around `isearch-string`, seven icons.
- `menu-bar-menus-tests.scm` +2 (11): the Undo/Redo states and Paste's
  ring arm, forms read from the live menu item and evaluated in the
  test module.
- `tty-editor-tests.scm` +3 (347): the published state after a search,
  the `:visible` form with both answers, and the Replace button
  end-to-end (search 888, click Replace, type XX, RET, y, RET ->
  "alpha XX beta" and "Replaced 1 occurrence").
- All suites pass; `tools/pty-check.py` to be run on the settled tree.

# Occur, and the Show hits button (2026-11-20)

Chris: *"Why doesn't your Replace toolbar item have a icon like emacs? And
why don't we have the 'Show Hits' toolbar item?"* - and then, while the
work was going on, *"and why does real emacs have the text 'Repeat
Forward' in the toolbar?"*

## The Replace icon

`isearch-tool-bar-map`'s Replace item asks for `"search-replace"` and
`isearch-tool-bar-image` turns that into `(find-image ...)` over
`schemacs/etc/images/`. **The file was never copied into this tree**:
Emacs's `etc/images/search-replace.xpm` and `.pbm` were, and now so are
`index.xpm` and `index.pbm` (the Show hits icon). `pgtk-win.scm` already
mapped both names ("etc/images/search-replace" to "edit-find-replace",
"etc/images/index" to ("gtk-search" "gtk-index")), so the theme icon
path works as soon as the file exists. Verified live: the item's image
slot is `(image :type xpm :file ".../etc/images/index.xpm" :mask
heuristic)`.

## Why real Emacs shows "Repeat forward" as text - and we did not

Two conditions have to hold before that text is drawn, and **the second
is where we were wrong**.

1. This desktop's GSettings says `org.gnome.desktop.interface
   toolbar-style` is **both-horiz** (`tool-bar-get-system-style`), and
   `xg_make_tool_item`'s label rule (`gtkutil.c:5594`) is

       label = (style == image || (vert_only && horiz)) ? nil : TOOL_BAR_ITEM_LABEL

   **The main bar's items are all `:vert-only t`** (`tool-bar.el:330-348`),
   so their labels are suppressed on a horizontal bar; **the isearch
   bar's items are not `:vert-only`** (`isearch.el:807-844`), so under
   both-horiz each draws its label.

2. The label has to survive `parse_tool_bar_item`'s size cut: a label
   longer than `tool-bar-max-label-size` is set to the empty string
   (`keyboard.c:10555`). **Emacs's default is 14**
   (`DEFAULT_TOOL_BAR_LABEL_SIZE`, `dispextern.h:3510`); this tree had
   **10**, transcribed wrong. `upcase-initials` of the caption "Repeat
   forward" is "Repeat Forward" - exactly 14 characters - so Emacs shows
   it and we discarded it. That is also why the user saw *Forward* and
   not *Backward*: "Repeat Backward" is 15 and real Emacs shows no label
   for it either.

With the default corrected, our search bar draws "Repeat Forward",
"Abort", "Finish", "Undo", "Replace", "Show Hits" and "Help", and no
label for "Repeat Backward" - Emacs 31.1's own answer. The main bar
stays icons-only because of condition 1, which is Emacs's answer for it
too. `tool-bar-tests.scm` pins both lists, and the "Open Directory"
label (14 characters as well) changed from "" to its Emacs value.

## What landed

`occur` (replace.el's second half) and `isearch-occur` (isearch.el's
command, placed in `replace.scm` for the same import-graph reason
`isearch-query-replace` is), plus the "Show hits" item in
`isearch-tool-bar-map` with `:image '(isearch-tool-bar-image "index")`.
`isearch-tool-bar-map`'s item list is now Emacs's eight, and the search
loop runs the command when the tool bar's key arrives.

**The search does not exit first.** Emacs 31.1's `isearch-occur` tests
the symbol property `isearch-exit` to decide whether to call
`isearch-done` first, and **nothing puts that property on it** -
measured, `(get 'isearch-occur 'isearch-exit)` is nil in
`emacs -Q -batch`, and no file in `lisp/` does the `put`. So the search
keeps running while `occur` displays its buffer, and the next key
continues the search; this tree's loop does the same (the command is
called through `call-interactively` and the loop goes on), where the
Replace button exits because *its* command's own first act is
`(isearch-done nil t)`.

## The primitives this needed, and what each changed

- **`rename-buffer` had the wrong shape**: it took a BUFFER argument
  where the Emacs DEFUN acts on `current_buffer`
  (`(rename-buffer NEWNAME &optional UNIQUE)`). `occur-1` and
  `rename-uniquely` are the callers that needed it as Emacs has it; the
  two call sites in `files.scm` and the three tests are updated. It is
  not a command here yet - the interactive spec reads a string, and
  `read-string` is above `buffer.scm`.
- **`rename-uniquely`** (`files.el:6747`) ported, and
  **`ngettext`** (`editfns.c:3180`) - the C's whole body is the
  placeholder `(if (= n 1) msgid msgid-plural)`.
- **`kill-buffer-hook`** (`buffer.c:4953`) added as a parameter and run
  by `%kill-buffer` exactly where the C runs it (`:1999`, after the
  query functions), **with the dying buffer current**
  (`set_buffer_internal`, `:1946`) - that is what makes occur's
  garbage-collect entry see the right buffer-locals. Emacs's
  `(add-hook ... nil t)` LOCAL half is not carried (`add-hook` here is
  one global list), so occur's entry is global and guards itself: a
  buffer that never ran occur answers #f and nothing is deleted.
- **`get-buffer-window`** grew Emacs's optional BUFFER-OR-NAME and
  ALL-FRAMES - `occur-1` asks with `all-frames` because the *Occur*
  buffer may be on another frame.
- **`save-selected-window`** ported as a macro over `dynamic-wind`;
  `select-window` here does not switch frames, so the per-frame half of
  Emacs's save/restore has nothing to put back and is named there.
- **`region-bounds`** (`simple.el:7279`) - the default function's single
  `(START . END)` pair; `region-extract-function` and rectangular
  regions are not carried.
- **`next-error`'s variables only**: `next-error-highlight`,
  `-highlight-no-select`, `-recenter`, `-message-highlight`, the hook,
  `next-error-found-function`, the `next-error`/`next-error-message`
  faces, `next-error-highlight-timer`,
  `next-error-overlay-arrow-position`, `next-error-last-buffer` and
  `next-error-found`. The command `next-error` itself is the
  compilation/grep subsystem and is not ported, so `occur-mode-map`'s
  `n`/`p` (`next-error-no-select`/`previous-error-no-select`), `l`
  (`recenter-current-error`) and `C-c C-f` are not bound; `c`
  (`clone-buffer`) and `e` (`occur-edit-mode`) are not either. Each is
  named in `replace.scm`'s header with what it waits for.
- **`face-differs-from-default-p`** (`faces.el:304`) ported;
  `occur-1` asks it of `list-matching-lines-prefix-face`.
- **`overlay-arrow-position`/`overlay-arrow-string`** carried in
  `xdisp.scm`; the renderer draws no overlay arrows, named there.

## What is not carried, and why (the honest list)

`occur-edit-mode` and `occur-after-change-function` (writing an edited
occurrence back to its source); `multi-occur` and
`multi-occur-in-matching-buffers`; `occur-word-at-mouse`,
`occur-symbol-at-mouse` and `occur-context-menu` (need
`thing-at-mouse`); the `occur-menu-map` `easy-menu-define` (no
easy-menu); `read-regexp`'s `M-s c` case-fold toggle and its `M-n`
suggestions list (this tree's `read-from-minibuffer` takes one DEFAULT,
not a list); and `set-buffer-file-coding-system` for the occur buffer's
coding system - `occur-engine` writes the same buffer-local slot
directly because `mule-cmds` is a front-end library `replace.scm` does
not import. `buffer-undo-list` is not a variable here to bind around
the initial erase.

## Two failures worth reading

**A parameter passed as a value.** `occur-1` handed
`*list-matching-lines-face*` - the parameter itself - to the engine,
and thirteen tests failed with `Invalid face` whose irritant printed as
`#<<parameter> ...>`. Every `*list-matching-lines-*` and
`*occur-excluded-properties*` read in the occur section is now called:
the file's oldest rule, and this is the third pass it has cost.

**The pty screen has faces in the middle of its text.** The new
`occur` check waited for `1:alpha 888 beta`, timed out with the line
plainly on the screen, and the reason is that the prefix column is drawn
in `list-matching-lines-prefix-face` and the matches in `match` - so a
face run sits between `1:` and `alpha` and the bytes are not contiguous.
The check strips escape sequences before asserting (`plain()`), and
waits for `*Occur*` rather than for the line. Its `RET` assertion expects
**C6**: `%c` is `current-column`, which is zero-based, and the `8` of
`888` after `alpha ` is column 6.

## Method notes

- **Write the block to a file, reader-check, splice - then compile.** The
  reader passed a form whose `if` binding list was one paren short; the
  *compiler* named it ("let: bad let"), and the shape of Guile's
  complaint is the tell: a form printed as `((define (occur-engine ...`
  means the *previous* top-level form is unclosed and swallowed it.
  Guile's `let` takes no bare bindings (`(let ((beg (point)) end)` is an
  error), `set!` takes one pair, and `while` is not Scheme - three
  mechanical rewrites of Emacs's code, each found by the compiler.
- **A `define-command` whose interactive form supplies fewer arguments
  than the procedure takes is an arity error at the key.** `occur`'s
  Emacs spec supplies REGION only when a region is active, so the
  procedure takes a rest argument; `occur-next-error`'s `"p"` supplies
  one argument for an optional RESET, so it does too. M-x occur failed
  with "Wrong number of arguments to #<procedure occur (regexp nlines
  region)>" until it did.
- **The pty check was seen failing before it passed** - twice, on the
  arity bug and on the face-run WAIT - which is what makes the green run
  evidence.

## Verified

- `occur-tests.scm` (new, 14): the listed lines and the seven-wide
  number field, occur-mode and read-only, the `occur-target` marker
  pairs, `occur-match` and the `match` face, context lines, collect
  mode, the no-match kill, the region header, `occur-next`'s positions
  and its "No more matches", RET to the occurrence, the revert
  arguments, rename, and `isearch-occur` quoting a literal and carrying
  the search's case folding. Every expectation measured on Emacs 31.1
  first.
- `tty-editor-tests.scm` +1 (348): the Show hits button clicked through
  a scripted `tool-bar` event - the *Occur* buffer holds the line, and
  the search is still running (the RET after the click ends it).
- `tool-bar-tests.scm`: the search bar is Emacs's eight items, and with
  nothing typed seven.
- `tools/pty-check.py` +1 (`occur`): M-x occur draws the numbered
  matching lines and says how many, a non-matching line is not listed,
  and C-x o, C-n, RET goes to the occurrence (mode line C6).
- All suites pass (76), the tree compiles with no new warnings, and a
  live Gtk editor under broadway ran `(occur "888" ...)` and drew the
  list; its isearch bar listed `isearch-occur` with its label and the
  `index.xpm` image.

## The jump-to-current-line bug the test found (same day)

`list-matching-lines-jump-to-current-line` was not exercised by the first
tests, and asking Emacs for it - the current line is inserted between the
matches carrying `current-line`, and the *window's* point is put just
after it - turned up two real defects in the port, both fixed and pinned
by `occur-tests.scm`'s new group:

1. **The `occur--final-pos` binding had too narrow an extent.** Emacs's
   `let` binds it around the erase, the engine *and* the read that puts
   the window's point there (`replace.el:2289-2316`). This port had a
   `parameterize` around only the engine call's init expression, so the
   read happened after the binding was gone and always answered #f. The
   `parameterize` now wraps the whole body, as the `let` does.
2. **The C's `if` answers the position, and a parameter's setter does
   not.** `(goto-char (if jump (setq occur--final-pos ...) (point-min)))`
   reads the position the `setq` returned; here `(*occur--final-pos*
   pos)` answers the unspecified value, and `goto-char` died with
   `(max #f 1)`. The branch computes the position in a `let`, sets the
   parameter and answers the position.

Both were found by *measuring Emacs first*, and the second only by
running the new test - the first's extent was invisible without the
read. `occur-tests.scm` is 16 now.

## The battery under the user's own load (same day)

The first full run on this tree gave **72/100** with 28 scattered
failures, every one of them a screen showing only the terminal startup
queries (`\e]11;?` and no content) - and the three that were rerun alone
(`truecolor`, `set-fill-column`, `scroll`) passed 3/3 on the same tree.
The machine was at load average 4.2-4.6 from the user's IntelliJ/Grails
processes, and that is the documented startup-race class: the checks
send keys before the editor's first draw, and `drive`'s quiet-and-drawn
startup wait is a guess at how long startup takes. **A scattered red
battery on a loaded machine is not a regression** - rerun the failures
alone, and rerun the battery when the machine is quiet.

# Occur's mouse, its colours, and the underline (2026-11-20)

Chris: *"in real emacs the show hits *occur* window is clickable with
the mouse to take you to the occurance. Also the 'xxx matches' line is
shown underlined and the linenumbers are shown in a different color."*
All three are in, and each needed a primitive the tree did not have.
DEPARTURES.md has the C for every rule; this is what the next session
needs before touching it.

## What landed

- **The symbolic mouse modifiers** (`character.scm`): `click`, `down`,
  `drag`, `double`, `triple`, `up` as `termhooks.h`'s bits, read out of
  event symbols by `parse-modifiers-uncached`/`event-modifiers` and
  written back by `event-convert-list`/`apply-modifiers`. The
  **implicit `click`** is `make_lispy_event`'s (`keyboard.c:6760`):
  `mouse-1` is `(click)` and `down-mouse-1` is `(down)`, and
  `event-convert-list` never writes `click` because the name carries it.
- **`*key-translation-map*`** and `key-translation-translate`
  (`keyboard.scm`), applied by `function-key-translate` after
  `function-key-map`. A translator's answer is a key sequence and only
  its first event is used; when that event is a **cons** - the mouse
  translation answers `(mouse-2 POSN)` - it becomes `*last-read-event*`
  and its car is the key. That is Emacs's `(setf (car last-input-event)
  newup)` (`mouse.el:193`), and it is what keeps the click's position.
- **`mouse.el:67-206` whole** (`mouse.scm`): `mouse-1-click-follows-link`
  (450 ms, and the negative/double/nil cases), `mouse-1-click-in-non-
  selected-windows`, `mouse--last-down`, the two translators,
  `mouse-posn-property`, `mouse-on-link-p`, and the four
  `key-translation-map` bindings.
- **`char-property-alias-alist`** (`intervals.scm` + `textprop.scm` +
  `font-core.scm`), which is what makes `font-lock-face` visible to a
  renderer that asks for `face` - Occur writes its line numbers that
  way. New primitives: `copy-tree` and `remq` (`subr.el`) in
  `subr.scm`; `nreverse` and `nconc` (`fns.c`) in `fns.scm`.
- **The Gtk underline** (`pgtk.scm`), `pgtk_draw_glyph_string`'s line:
  one pixel at `(descent + 1) / 2` below the baseline, minimum 1,
  clamped to the row - and **`:underline` is `t` or a colour**, which
  omarchy's themes use. `realize-face-token` keeps the value now; it
  tested `(eq? #t ...)` before, so a themed editor drew nothing.

## The three bugs this pass found, and the shape of each

1. **A parameter read raw in a seam.** `lookup-char-property`'s alias
   reader was installed with `(*current-buffer*)`, and that parameter is
   #f whenever no `set-buffer` has pinned a buffer - the ordinary case.
   So the reader answered the *global* list for every such buffer and
   `font-lock-face` never resolved live, while a unit test that passed a
   buffer explicitly passed. It reads `(current-buffer)` now.
2. **`when` as a value.** `(when action ...)` at the end of the click
   translator answers the *unspecified* value when ACTION is #f, which
   is true in Scheme, so every ordinary click off a link came back as
   `#<unspecified>` and the dispatcher raised "a key is a string or a
   vector of events". `(if action ... #f)`.
3. **A translated event lost its position.** The translator answered
   `(vector 'mouse-2)` - the key alone - where Emacs mutates the event in
   place, so the command ran with no posn and acted on point instead of
   the clicked line. The answer is the whole event cons, and
   `key-translation-translate` installs it.

## Verified live (Gtk under broadway :5, `SCHEMACS_INSTANCE` named)

- The *Occur* buffer's prefix carries `(font-lock-face shadow)`,
  `follow-link t`, `help-echo "mouse-2: go to this occurrence"`, and
  `(get-text-property 49 'face)` answers `shadow` through the alias.
- A press+release driven through `dispatch-key` on the occurrence line
  landed in `occur-vis.txt` at point 7 (the match) with
  `*last-read-event*`'s car `mouse-2`.
- A `pgtk-write-screenshot!` scanned for the theme's underline colour
  (`#3f8f8a`): two solid runs under the two wrapped header rows, and on
  the occurrence rows only the prefix glyphs - body text in the default
  foreground. **A screenshot is a workable oracle for a face** when the
  colour is known; scan for long runs of the exact RGB rather than
  eyeballing it.

## Tests

- `character-tests.scm` +2: the modifier table and the convert table,
  every row `emacs -Q --batch`'s answer.
- `mouse-tests.scm` +6 (51): `mouse-on-link-p` at a posn and at a
  buffer position, the translator's answer carrying its posn,
  `key-translation-translate` setting `*last-read-event*`, the off-link
  case, and the two time rules (a 0 ms limit and a negative one).
- `font-lock-tests.scm` +2 (15): the alias resolving through
  `get-text-property` with the mode on and off, and the global list
  never moving.
- `pgtk-tests.scm` new `schemacs_pgtk_underline` group: a pixel in a
  **space** cell is inked only when the face is on - the control render
  is what makes it a test of the underline rather than of a glyph.

## Still named, not carried

- Click counting (`double-`/`triple-mouse-N`): neither front end makes
  the events, and the `'double` branch of the translator can never see
  one until a click clock exists.
- The terminal has no mouse reporting, so an Occur line is not clickable
  on a tty (`term.scm` names it).
- `mouse-1-double-click-prefer-symbols` and `mouse-skip-word`.
- `[follow-link]` key bindings are consulted without a position
  (`key-binding` takes none here).

# Where else Emacs has a tool bar (survey, 2026-11-20)

Asked while the isearch bar was being finished. Every mode below
installs a **buffer-local `tool-bar-map`**, which this tree already
honours (`%tool-bar-map` reads the buffer-local first); what each needs
is the map and the commands it names.

| library | tool bar | in this tree? |
|---|---|---|
| `isearch.el` | `isearch-tool-bar-map` (8 items) | **yes, done** |
| `help-mode.el` | `help-mode-tool-bar-map` (quit, search, back/forward) | library exists; map not ported |
| `dired.el` | only `dired-click-to-select-mode` sets one | library exists |
| `menu-bar.el` | the main bar's `tool-bar-map` | yes |
| `window-tool-bar.el` | `window-tool-bar-mode` - a per-window bar drawn in the tab-line area, for every buffer | **not ported**; a redisplay feature of its own |
| `info.el`, `doc-view.el`, `compile.el`, `grep.el`, `gud.el`/`gdb-ui`, `vc-dir.el`, `log-edit.el`, `eww.el`, `dictionary.el`, `package.el` (`package-menu-mode`), `mpc.el`, `artist.el`, `xwidget.el`, `rmail.el`/`rmailedit.el`, `gnus/*` (group, summary, article, message), `mh-e/*`, `newsticker.el`, `cus-edit.el` | each its own map | libraries not ported |

So the pattern is one map per mode, not a subsystem: a mode's
`define-derived-mode` body sets `(setq-local tool-bar-map ...)`. The two
worth adding next are `help-mode`'s - but only half of it: its back and
forward items name `help-go-back`/`help-go-forward`, which are the xref
stack this tree does not carry (`help-mode.scm`'s header says so), while
`quit-window` and `isearch-forward` exist - and the `window-tool-bar`
mode, which is the only one that is a *redisplay* feature rather than a
map.

## The click that still did nothing: `double-click-fuzz`, and events
## decoded at arrival (2026-11-20, later the same day)

Chris, after the pass above: *"clicking in the occur buffer still does
nothing, unlike emacs."* The translation machinery was right - the bug
was in **how the Gtk front end decided that a release was a click at
all**, and in **when it built the mouse event**.

### The drag test was quantized to cells

`mouse-1`'s follow-link translation has a time rule *and* the release
must be a click: GNU Emacs decides that at the button release
(`keyboard.c:6668-6682`) with

    - double_click_fuzz < release_x - press_x < double_click_fuzz
    - double_click_fuzz < release_y - press_y < double_click_fuzz
    and double_click_fuzz > 0

in **pixels**, `double-click-fuzz` defaulting to 3 (`:14449`). This
tree compared `(pgtk-event-cell release)` with `(pgtk-event-cell
press)` - cells are 9 by 20 pixels - so **one pixel of jitter across a
cell boundary became a `drag-mouse-1`**, and `mouse-set-region` ran
instead of the click. `drag-mouse-1` is deliberately not in
`key-translation-map` ("dragging never follows the link"), so the click
did nothing. Near a boundary that is a coin flip, which is why it
looked like "nothing ever works" from a mouse that moves a pixel or
two when you click.

Ported: `double-click-fuzz` (`keyboard.scm`, a plain variable, default
3), `pgtk-event-pixel` (the rounded Gdk coordinates), and the release
handler's comparison as the C writes it; `<pgtk-display>`'s
`press-cell` is `press-pixel`.

Measured live on Gtk under broadway, with synthetic Gdk button events
posted through `gdk_display_put_event` (see below):

| press -> release | before | now |
|---|---|---|
| same cell | mouse-1 -> occur-mode-goto-occurrence | same |
| **2 px apart across a cell boundary** | `drag-mouse-1` -> `mouse-set-region` | **click -> occur-mode-goto-occurrence** |
| 10 px apart | `drag-mouse-1` -> `mouse-set-region`, region left active | same |

The press is also **consumed** by the release that reads it, and a
release with no press before it is dropped - the C's "If we did not see
a down before this up, ignore the up" (`keyboard.c:6649`, `:6592`). A
release belonging to a menu selection is exactly that case.

### Mouse events are now made in the signal handler

`pgtk-item->event` used to hold the *GdkEvent proxy* in the queue and
read its coordinates when the queue was drained - the one thing
`pgtk-key-item`'s own comment warns against ("**a queued event outlives
the signal emission**... what is queued is the integer the decode
produced, not the platform event"). For a click made while a nested
read is outstanding (a prompt, an isearch) the drain happens after the
signal handler returns, i.e. after Gtk has freed the event: a
use-after-free whose symptom is a silently wrong position, and so a
click on no link. The press handler and the release handler now build
`(pgtk-mouse-event ...)` (and, for a drag, both positions) in the
handler and queue it tagged `event-item` - the tag `pgtk-key-item` uses
for a key, since Emacs draws no distinction: `kbd_buffer_store_event`
stores every event the same way.

### How the live clicks were driven

`gdk_test_simulate_button` is X11-only (it returns FALSE on
broadway/Wayland), but `gdk_display_put_event` takes any
`GdkEventButton` the caller builds, copies it, and Gtk dispatches it to
the widget - the whole real path, signal handlers included. The struct
is written into a bytevector at the x86-64 offsets (type 0, window 8,
send_event 16, **time 20**, x 24, y 32, axes 40, state 48, button 52,
device 56, x_root 64, y_root 72); getting `time`'s offset wrong shifted
every later field, and the event was dropped. **This is the way to
click a running editor without a hand on the mouse** - the compositor
method this file forbids is not involved.

Two traps in using it: a posted event is delivered only when the
editor's main thread returns to `gtk_main`, so the *state queries* that
follow a click must be a separate REPL call; and a REPL round trip can
take longer than `mouse-1-click-follows-link`'s 450 ms, so a debugging
session that sees "the translator said no" should check `mouse--last-down`
against the wall clock before believing it.

# The mark in *Messages*, and the mouse face (2026-11-20)

Two things Chris reported while using the editor, and what each turned
out to be. DEPARTURES.md's 2026-11-20 section has the C every rule was
taken from.

## `C-SPC` and `M-w` in `*Messages*`

"Mark and copy has no effect in that buffer." It is the one buffer that
is both edited and logged into: `set-mark-command` messages "Mark set",
`message_dolog` inserts that into the current buffer, and the insert set
that buffer's `deactivate-mark`, so the command loop deactivated the
region at once. Two C facts fixed it and one was a primitive that was
wrong everywhere:

- `message_dolog` inserts with `prepare = false` (`xdisp.c:12406`) and
  saves/restores `Vdeactivate_mark` (`:12359`, `:12526`). The port binds
  `*inhibit-modification-hooks*` beside `*inhibit-read-only*` now, and
  restores the flag after the switch back.
- `prepare_to_modify_buffer_1`'s `deactivate_mark` write sits **after**
  `if (inhibit_modification_hooks) return;` (`insdel.c:2167` vs
  `:2189`); the port had it outside the gate.

**The way to see a bug of this shape**: a flag that a *primitive* sets
during a *command the user ran in the buffer the primitive writes to*.
`*Messages*` is the only such buffer, which is why only it was broken.
Reproduce at a pty (C-x b *Messages*, C-SPC, C-n, M-w) or headlessly
(`message` with `*Messages*` current, then read its `deactivate-mark`).

## The Occur click error: `make-overlay` takes markers

`Wrong type argument in position 1: #<marker … charpos 153>` came from
`occur--highlight-occurrences` → `(make-overlay (car target) (cdr
target))`, where an `occur-target` is two **markers**. `Fmake_overlay`
(`buffer.c:3650`) coerces markers and refuses one in another buffer;
ours handed them to `min`. Ported through
`*check-fixnum-coerce-marker-function*` (declared in `buffer.scm`,
installed by `marker.scm` - the coercion is `marker.c`'s and
`marker.scm` is above `buffer.scm`). Tested in `buffer-tests.scm`.

**`CHECK_FIXNUM_COERCE_MARKER` is a family**: any C position argument
that says "a number or marker" needs it. `goto-char` had it;
`make-overlay` did not. The next one that does not will show up as "`min`
/ `max` got a marker", because that is where the coercion is skipped.

## The mouse face (hover highlighting)

Occur lines and Dired names carry `mouse-face`, and Emacs highlights the
run under the pointer. That is `note_mouse_highlight` (`xdisp.c:37061`),
run from the toolkit's motion handler on **every** movement
(`pgtkterm.c:5945`) - *not* gated on `track-mouse`; `track-mouse` gates
only whether a `mouse-movement` *event* is made (`some_mouse_moved`,
`keyboard.c:1290`).

What is here: the state in `xdisp.scm`
(`%mouse-face-window`/`-beg`/`-end`/`-attrs`, `mouse-highlight` as the
plain defvar), `note-mouse-highlight`/`mouse-face-at`/
`clear-mouse-face!`, the painting through `attrs-at-buffer-position`
under `*drawing-window*` (bound by `display-window!`), the run split in
`face-change-limit`, and in `pgtk.scm` the per-report call plus a
`leave-notify-event` clear. `mouse-tests.scm`'s
`schemacs_editor_mouse_face` pins the primitive and the painted row.

### Traps this cost

- **`track-mouse` is a plain variable here, not a parameter.** Written
  `(when (track-mouse) …)` it applies `#f` - "Wrong type to apply: #f"
  from inside a Gtk signal handler, which is fatal and reads as a crash
  in something else. Read it as `track-mouse`.
- **`posn-at-x-y`'s unit is the *display's*, which for Gtk is cells.**
- `pgtk-event-pixel` returns Gdk pixels; the handler converts with
  `pgtk-event-cell` before anything that takes a posn.
- `(window-top w)` in a live Gtk frame answered pixels where the
  window record's `top` was cells - do not mix them when computing a
  posn by hand. `posn-at-x-y` is the arbiter.
- **Reading the flag through the REPL is only meaningful when the
  window really shows the buffer you think.** An early probe read
  `*Messages*`' own `deactivate-mark` and looked like a live bug in the
  file buffer; always print `(buffer-name (current-buffer))` beside it.
- **A `mouse-face` run in the middle of a face run needs the run split
  at its edges** (Occur's runs start at the line beginning, so Occur
  alone never showed this; Dired's shape does).
- The pty battery's screen is per-row cells: to read pixels, screenshot
  the frame (`pgtk-write-screenshot!`) and histogram the PNG - with a
  HiDPI frame every row is two device pixels per cell row, so sample
  with the scale factor in hand (row N is at `N × row-height × scale`).

# The mode line as a mouse handle, and the scroll-bar plan (2026-11-20)

## Done and tested

The mode line is a drag handle and a click target exactly as in
`mouse.el:3818-3826`: `down-mouse-1` drags the window's bottom edge
(`mouse-drag-mode-line` → `mouse-drag-line` → `adjust-window-trailing-edge`),
`mouse-1` selects the clicked window, mouse-2 deletes the other windows,
mouse-3 deletes that one; `[vertical-line ...]` is the same pair.
DEPARTURES.md has the whole list of primitives that had to land with it
(`adjust-window-trailing-edge`, `window-at-side-p`, `one-window-p`,
`window-resize-pixelwise`, `mouse-absolute-pixel-position`,
`set-mouse-position`, `raise-frame`, `tty-type`, `minibuffer-window`,
`mouse-position-in-root-frame`, the three display generics with their
pgtk methods, and the mode-line posn's string). Two pipeline pieces were
real departures and are fixed: `posn-at-x-y` now answers the drawn mode
line string as `(STRING . CHARPOS)` (Emacs's `store_mode_line_string`),
and `lookup-keymaps` is now `current_active_maps (Qt, position)` - the
click's window buffer is made current, the string's `keymap` property
goes above the minor modes and its `local-map` below them, and the
buffer position's properties are read through `get_local_map`
(`*get-local-map-function*`, installed by `editfns.scm`).

`mouse-tests.scm`'s `schemacs_editor_mouse_mode_line` covers it; suites
76/76 and mouse-tests 73.

**Traps paid for**: `*last-read-event*` is a *parameter* - writing
`(let ((event *last-read-event*)) ...)` gives you the parameter object
and a drag that does nothing (the echo said nothing because the error
was swallowed by the command loop's guard; `frame-message` is where it
shows). `message` and `set!frame-message` are not imported in
`mouse.scm`; a debug line with either raises *inside* the move lambda
and reads exactly like "the drag does nothing". Name debug output with a
scratch variable or check the compiler.

## The mode line's item keymaps - what is left

`%`-construct output now inherits the format string's text properties
(`inherit-mode-line-properties`, mirroring `display_mode_element`'s
`set-text-properties` at `xdisp.c:28520`), which is the mechanism
`bindings.el` uses - `(propertize "%1*" 'local-map MAP)` is what makes
the flag clickable. What is still missing:

1. The `local-map`s and commands: `make-mode-line-mouse-map`,
   `mode-line-toggle-read-only`, `mode-line-toggle-modified`,
   `mode-line-widen`, `mode-line-change-eol`, and the propertized
   constructs in `*mode-line-format*` (modified, remote, `%z`/eol,
   `%n`, buffer id, position).
2. The menus: `mode-line-mode-menu` (minor modes, built from
   `minor-mode-list`), `mode-line-major-mode-keymap`'s
   `mouse-menu-major-mode-map`, and `popup-menu` at the click position.
   `popup-menu`/`x-popup-menu` and the menu-item machinery already exist
   (menu-bar work).
3. `help-echo` display on hover (the echo area or a tooltip) and the
   mode-line `mouse-face` (`mode-line-highlight`) paint. The latter
   needs `draw-mode-line!` to honour the mouse-face state for a run of
   the mode-line *string*, the string analogue of what
   `attrs-at-buffer-position` does for buffer text; `note-mouse-highlight`
   currently handles buffer text only (`posn-area` `'mode-line` clears).

Placement: those commands are `bindings.el`'s, so a `bindings.scm` (or
`xdisp.scm`'s mode-line section) is their home; the coding-system and
eol ones need `mule-cmds.scm` (`set-buffer-file-coding-system`,
`describe-coding-system`) which is above `xdisp.scm` - a seam, as usual.

## Scroll bars - recon, not written

Read `gtkutil.c`. Emacs's Gtk frame is `GtkWindow → GtkBox → GtkFixed`
(`FRAME_GTK_WIDGET (f) = wfixed`, `gtkutil.c:1670`), Emacs draws the text
on the fixed, and each scroll bar is a `GtkScrollbar` inside a
`GtkEventBox`, `gtk_fixed_put` as a child of that fixed
(`xg_finish_scroll_bar_creation`, `:4596`), moved and resized per window
by `xg_update_scrollbar_instance_status_and_geometry` (`:4780`, called
from `display_vertical_scroll_bar`). The widget's `change-value` and
`button-release-event` callbacks store a `VERTICAL_SCROLL_BAR_CLICK_EVENT`
handled by `scroll-bar.el`'s `scroll-bar-toolkit-scroll`.

For this tree: the frame is `GtkWindow → GtkBox → GtkDrawingArea`, and a
GtkDrawingArea cannot have children, so the first structural step is a
`GtkFixed` between the box and the drawing area (drawing area at 0,0,
scroll-bar event boxes as siblings above it) - the renderer does not
move. The geometry is cell-quantised where Emacs is pixel-native: the
bar's width is `ceiling(bar_px / cell_width)` columns, `window-body-width`
subtracts them, and the widget's `set_size_request` is `columns ×
cell_width` so it lands on the grid (a named departure, the only visible
one). Then: real `window-scroll-bars`/`set-window-scroll-bars`
(`frame.scm` answers a terminal's answers today), `scroll-bar-mode`
(`scroll-bar.el`), the `vertical-scroll-bar` frame parameter, a per-window
display hook in the redisplay pass, the `(vertical-scroll-bar PART POSN)`
event kind through the front-end queue, `scroll-bar-toolkit-scroll`, and
the CSS from the `scroll-bar` face. The guile-gi ownership rule applies
(hold the widget proxies for the display's life - the menu/tool bar
taught that).

# The scroll bars, the pointer's shape, and the frame's separators
# (2026-11-20)

Chris asked for two things - "the mouse cursor should change when you
hover the mode line" and "port the scroll bars first because that changes
the whole layout" - and then, from using it, four departures in what had
landed: the bars of stacked windows met across the mode line, the mode
line did not reach the frame's edge, a column of `|` glyphs was drawn
beside the bars in Gtk, and the pointer did not change for a horizontal
drag. All four are fixed; DEPARTURES.md's 2026-11-20 section has the C
each rule was taken from.

## What landed

* **The pointer's shape** - `note_mouse_highlight`'s cursor half in
  `xdisp.scm` (`pointer-kind`, `mode-line-draggable?`, `string-pointer-at`,
  `string-keymap-at?`, `text-pointer-at`, `frame-cursor-for-posn`,
  `note-frame-cursor`) and `pgtk.scm`'s `display-define-frame-cursor`
  method, with the seven per-frame Gdk cursors held for the display's
  life. `note-mouse-highlight` now asks for the shape *before* the face
  work and regardless of `mouse-highlight`, which is what makes a
  draggable mode line show the vertical-drag cursor.
* **`ON_VERTICAL_BORDER`** - `posn-at-x-y` answers a `vertical-line` area
  for the one-column strip at a line row's edge (the part over a toolkit
  scroll bar) and for the border column of a no-scroll-bar frame's text
  rows; `frame-cursor-for-posn` maps it to the horizontal-drag cursor.
  `[vertical-line down-mouse-1]` was already bound to
  `mouse-drag-vertical-line`.
* **`w->force_start`** - `set-window-start!` sets it; `scroll-to-cursor!`
  honours it for the selected window; `set-window-buffer!` writes the
  start *without* it, as `set_window_buffer` does; the renderer clears it
  on every non-selected window it draws.
* **The bars** - `display-set-window-scroll-bar` is fed the text area's
  box (`window-body-top` / `window-body-height`), the mode and tab lines
  are drawn across the window's whole width, and the minibuffer window
  gets no bar.
* **The separator** - `display-draw-vertical-border`, the C's
  `draw_vertical_window_border` hook: a one-pixel `vertical-border` line
  over the text area. With scroll bars the frame draws no separator at
  all; a terminal keeps the `|` glyph column.
* `window-move-screen-lines`'s backward direction stepped **two** lines
  per iteration; `(window-scroll w -6)` moved twelve. One line now.

## The three regressions this shook out, and their shapes

1. **`set-window-buffer!` set `force_start`** because it wrote the start
   with the DEFUN. The flag then survived on the minibuffer window, whose
   buffer the composite redisplay swaps in and out, and the next
   redisplay moved the prompt's point into the read-only prompt field:
   every typed key signalled "Text is read-only" and the answer came back
   as the default. Symptom: `(read-from-minibuffer "Q 888 with: " ...)`
   with X X RET answered `"888"`. If a prompt ever swallows typing again,
   check the window's force flag first.
2. **The completion display called `set-window-start!`** where Emacs's
   `temp-buffer-window-show` does not. The first `M-<down>` in the
   completions window then kept the start and moved point into the middle
   of the list: the selection landed on the help line and the wrap never
   happened (`pty-check.py`'s `completion-scroll`, deterministic alone).
3. **`window-move-screen-lines`'s backward branch** (above) - a
   pre-existing bug that only the page-scroll tests would have noticed,
   and did not because they asserted the rule from the current geometry.

## How to look at a Gtk frame when developing

* **`pgtk-write-screenshot!` writes the cairo surface, not the window.**
  Toolkit widgets - the menu bar, the tool bar, the scroll bars - are not
  in it. Bar *geometry* is queried from the widget records
  (`pgtk-scroll-bars` is an alist of `(window . bar-vector)`;
  `widget:get-allocated-width/height`, `widget:get-margin-start/top` live
  in `(schemacs ui gtk pgtk-names)`, not in `pgtk`); the mode line's
  width and the separator's presence *are* in the surface, so scan its
  pixels (`magick file -depth 8 rgb:-` and index it).
* **Broadway has no pointer.** `gdk_window_get_device_position` answers
  (0,0), so a drag's motion sampling is always zero there; the drag
  *start* is still testable.
* **Posting a real Gdk button press from the REPL works**, and is the way
  to click without a hand on the mouse: build an 88-byte
  `GdkEventButton` (type 4 = press, 7 = release; window pointer at 8,
  time at 20, x/y doubles at 24/32, state 48, button 52, device 56,
  x_root/y_root 64/72), then `gdk_display_put_event` through
  `dynamic-func`. A press in the text area moves point, so the delivery
  can be checked before trusting anything else. The event is dispatched
  when the main thread next runs the Gtk loop, so read the resulting
  state in a *separate* REPL call.
* **A mode line can only be dragged when its window is not the frame's
  bottom one** (`mouse-drag-mode-line`'s `window-at-side-p` guard,
  `mouse.el:1088`): the bottom one resizes the minibuffer, and only when
  the minibuffer is active or `resize-mini-windows` is nil. A press on
  the bottom mode line doing nothing is Emacs's behaviour, not a bug.
* **A guile-gi subclass slot named like the stub's is a trap**: the test
  display already has a `cursor` slot recording the *drawn* cursor
  `(ROW COLUMN TYPE)`, and a subclass slot with the same name/accessor
  silently broke the stub's own setter ("No applicable method for
  `set!test-display-cursor`"). The cursor tests' slot is `frame-cursor`.
* `window-tab-line-height` is `frame.scm`'s, not `xdisp.scm`'s - a test
  importing it from xdisp fails at load, which the runner reports as
  "DID NOT RUN".

## Tests

* `scroll-bar-tests.scm` 68 (was 58): the bar is the text area's box - a
  one-row-short height, a tab line pushing it down a row - and the
  separator: no border line at all with scroll bars, exactly one over the
  text area without them.
* `mouse-tests.scm` 84 (was 73): the pointer's shape - text, hand over a
  `mouse-face` run, the scroll-bar cursor for a `vdrag` pointer property,
  nontext on the frame's bottom mode line, vertical-drag on a non-bottom
  one, nontext when the mode-line string carries a keymap, and
  horizontal-drag on a side-by-side window's edge - on its mode line and
  on a text row.
* `tools/pty-check.py`'s `completion-scroll` is the regression check for
  the `force_start` completion bug; it failed deterministically before
  the fix.
* `pgtk-tests.scm` 117: the pointer queries and `raise-frame` are methods
  of the *display interface's* generics, asked with
  `compute-applicable-methods`. A sweep of all 48 `define-method`s in
  `pgtk.scm` against its dispnew import list found exactly three dead
  ones - the two pointer queries and `display-raise-frame` - and all
  three are imported now. Run that sweep after touching an import list:

      python3 - <<'PY'
      import re
      src=open('schemacs/ui/gtk/pgtk.scm').read()
      methods=set(re.findall(r'\(define-method \(([^\s()]+)', src))
      start=src.index('(only (schemacs dispnew)')
      depth=0; i=start
      while i < len(src):
          c=src[i]
          if c=='(': depth+=1
          elif c==')':
              depth-=1
              if depth==0: break
          i+=1
      names=set(re.findall(r"[^\s()]+", src[start:i+1]))
      print(sorted(m for m in methods if m not in names))
      PY


## The separator was one column right, and the pty `resize` check said so

Changing the mode line to span `window-width` left the separator's
column computed from the same `x0`/`width` bindings (`x0 + width`), which
used to be the body's right edge and is now one past the window's last
cell. Result: on a 60-column terminal `C-x 3` put `|` in column 30
instead of 29, and `tools/pty-check.py`'s `resize` failed at all three
widths, deterministically (`100 -> 50, 60 -> 30, 80 -> 40`). It is
`window-left + window-width - 1` now. **A binding reused for a new span
is the trap**: the mode line's width and the border's column are two
different spans that coincided while both were the body's.

## Verified

* All 77 suites pass (`scroll-bar-tests` 68, `mouse-tests` 84,
  `tty-editor-tests` 348, `pgtk-tests` 117).
* `tools/pty-check.py` **100/100**, exit 0, on the tree as committed -
  the first full green battery after the pointer-query fix.
* `imports.scm` regenerated for the three new exports
  (`display-draw-vertical-border`, `frame-has-vertical-scroll-bars?`,
  `window-leftmost?`).
* **A running editor keeps the code it started with**: the layout and
  cursor fixes need a restart before Chris can see them.

## Dragging the mode line never resized anything - a dead generic

The whole drag path was fine: the press reached `mouse-drag-mode-line`,
the transient map caught the motion events, `track-mouse` became
`dragging`. What was dead was **the pointer query**:
`pgtk.scm`'s `define-method` for `display-mouse-absolute-pixel-position`
(and `display-set-mouse-pixel-position`) was written without importing
the name from `(schemacs dispnew)`, so it made a *private generic*
in `pgtk.scm`. The real generic kept only its default `#f` and
`mouse-absolute-pixel-position` answered `(0 . 0)`: every drag sample was
zero, so `growth` stayed zero and no window moved. The cursor worked
because that generic *is* imported.

Measured: `(mouse-absolute-pixel-position)` → `(0 . 0)` while
`(pgtk-pointer-cell d)` answered a real cell. The fix is two names in the
import list. `pgtk-tests.scm` now asserts that the real generics have two
applicable methods for a `<pgtk-display>`, using
`compute-applicable-methods` - a test that merely *calls* the function
cannot tell a registered method from the default `#f`. (Applicability is
decided for the arguments given: ask the four-argument setter with four.)

**This is the missing-import class with a new hiding place**: `define-key`
and `define-method` both create their binding, so neither the compiler
nor the loader complains. If a display seam "does nothing", check that
its name is imported before checking anything else.

## "Failed adjusting window" - the combination axis, and a `set!` that is true

Two bugs behind Chris's horizontal-drag error, both in `window.scm` /
`frame.scm`:

1. **The combination axis was inferred from the children's rectangles**;
   Emacs stores `w->vchild`/`w->hchild`. A combination down to *one* child
   has no geometry to infer from, so a one-child vertical combination was
   taken for a horizontal one: the drag's walk stopped at it instead of
   climbing to the real horizontal combination, tried to widen a
   frame-wide window, and `window-resize-apply` refused - "Failed
   adjusting window". The axis is a stored slot now
   (`window-combination-axis` / `set-window-combination-axis!`), set by
   the splits and by `combine-windows`; `window-stacked?` takes the parent
   window and reads it; `window-combined-p`, `window-top-child`,
   `window-left-child`, `%window-resize-check`, `%window-resize-apply-1`
   and `scale-window!` pass the parent. A window with no stored axis and
   two or more children falls back to geometry.
2. **`(not (set! left right))` is always false**: `setq` answers the
   value it set, `set!` answers the unspecified value, which is *true*.
   The "No window on the right/below this one" guard never fired and a
   nil window reached `window-min-size`. Same class as the `when`-in-
   value-position notes; grep for `(not (set!`, `(or (set!`, `(and
   (set!` in ports of Elisp that use `setq` as an expression.

`tools/window-resize-fuzz.scm` is the check that found it and proves the
fix: 300 random trees, every window, both directions, ±1/±2.
**1508 failures before, 0 after.** It exits 1 on any failure - run it
after touching `window--resize-*`, `split-window` or the window record.

`window-tests.scm` 18 pins the stored axis and the nested horizontal drag
(the pair resizes, the frame-wide window keeps its width).

# The mode line as a set of buttons (2026-11-20)

Chris: *"ok implement some of the missing menus and features of the mode
line"*. This pass is the items `bindings.el` makes clickable, the
commands they name, and the hover highlight they ask for.
DEPARTURES.md's 2026-11-20 section has the C each rule came from and the
full list of what is left.

## What is in

- **`xdisp.scm`**: `make-mode-line-mouse-map` (`bindings.el:30`), the
  four commands (`mode-line-toggle-read-only`, `-toggle-modified`,
  `-widen`, `mode-line-change-eol`) and the buffer-name pair
  (`mode-line-previous-buffer`/`-next-buffer`), all `define-command`s
  with `(interactive "e")` and `with-selected-window` on the clicked
  posn's window - so a click acts on *that* window's buffer.
- **The constructs**: `mode-line-modified` (`%1*` and `%1+`, each with
  its own `local-map` and the highlight face), `mode-line-remote`,
  `mode-line-narrowed` (the `%n` element), and
  `propertized-buffer-identification` / `mode-line-buffer-identification`
  (`%12b` with the map that makes mouse-1 previous and mouse-3 next).
- **The EOL mnemonic is propertized** with a `keymap` for
  `mode-line-change-eol` and a help string, as `mode-line-eol-desc` is.
- **The hover face on a mode line** (`note-mouse-highlight`'s string
  branch): the run comes from the clicked string's `mouse-face`
  property and `draw-mode-line!` paints those characters with the value
  merged over the face they already have. A mode line whose run changed
  is redrawn because the run is part of `window-last-mode-line`'s
  record.
- **`coding.scm`**: `define-coding-system-alias` with Emacs's
  subsidiaries, the four `mule-conf.el` aliases, the real
  `coding-system-change-eol-conversion` and
  `coding-system-change-text-conversion`; `mule.scm`'s
  `merge-coding-systems` now carries both of the C's branches.
- Tests: `mode-line-tests.scm` (37, a new suite), `coding-tests.scm`
  62 + 14, and `display-supports-face-attributes-p` answers `:box` on a
  window-system frame so a Gtk frame gets `mode-line-highlight`'s
  rosette rather than the tty's `:inherit highlight`.

## What to know before touching it

- **`%1*` is the read-only item and `%1+` the modified one.** Both show
  the *state* (both are `*` when modified), but a click on the first
  toggles read-only and a click on the second toggles modified. A first
  test that expected clicking `*` to clear the modified bit was testing
  the wrong item.
- **The EOL command reaches `set-buffer-file-coding-system` through a
  seam** (`*set-buffer-file-coding-system-function*` in `xdisp.scm`,
  installed by `mule-cmds.scm` as it loads, as a one-argument
  `lambda`). The renderer is below `files`, so it cannot import the
  command. A session without `mule-cmds` gets an error naming the
  function - write error templates with `~a`, not `%s`: `(error "%s"
  x)` shows the literal `%s` because the reporter only formats messages
  containing `~`.
- **A seam installed for a function in the same library goes after its
  definition** (the `read-char-event` rule), and the function must take
  the arguments the caller gives - `set-buffer-file-coding-system`
  takes three and the command gives one.
- **The hover run is compared by content** (`equal-including-properties`
  against the recorded string), because a redisplay formats a fresh
  string each time. The record includes the run so a pointer moving
  onto or off an item redraws a line whose characters did not change.
- **`display-supports-face-attributes-p` is evaluated when a frame
  recalculates the faces**, which the Gtk front end does inside
  `with-gtk-display` *after* setting `*window-system*` - that is why
  `(supports :box t)` can answer per front end.
- **The test fixture must clear the modified flag**: inserting text to
  build a buffer marks it modified, and `%1*` then reads `*`.
- `(buffer-read-only? ed)` reads the buffer's *slot*; a
  `set-buffer-local-value!` of `'buffer-read-only` does nothing to it.
  Use `set!buffer-read-only`.

## The press that precedes every click (2026-11-20, the same day)

Chris, on the finished items: *"Wrong type argument in position 2: #f"*,
*"when clicking mode"*, *"and when clicking buffer name"*. A click is a
`down-mouse-1` and then a `mouse-1`; the item's map binds only the
release, and the dispatcher's "last event alone" fallback retried the
press in the whole map list, found the text command `mouse-drag-region`,
and ran it on a mode-line position. Emacs *disposes of* an unbound mouse
up/down click instead (`read_key_sequence`, `keyboard.c:12115`).

- `%unbound-mouse-reduction` / `%run-reduced-click` in `keyboard.scm`
  carry that fallback: drag/double/triple clicks reduce to their plain
  click in the same map, up/down clicks are dropped silently, and only a
  non-mouse event still takes the last-event-alone rule that `C-x C-g`
  needs.
- **The callbacks' `let*` became a `letrec*`**: `fail` calls
  `fail-alone` and reads `prefix-maps`, both bound *after* it in the
  list. A `let*` leaves them unbound inside the closure and the compiler
  says "possibly unbound"; the failure appears only on the mouse path.
- A **no-motion `mouse-1` release does not end a mode-line drag** -
  Emacs drops it too; the drag map's exit is `[drag-mouse-1]`.
  `mouse-tests`' drag test was sending `mouse-1` as "a key the map does
  not bind", which only worked because of the old fallback; it sends
  `drag-mouse-1` now.
- **`mode-line-tests` must import `(schemacs mouse)`**: the
  `[mode-line ...]` bindings are that library's, and without it a click
  on a plain stretch has no binding at all - which looked like a bug in
  the click path for half an hour.

## The hover box and the item a run belongs to (2026-11-20, second report)

Chris, using it: *"mouse over in real emacs mode line draws a box around
it, not just lines top and bottom. also each character in the left mode
section is a separately highlighting target, whereas you have 3
characters highlighting at once."* DEPARTURES.md has the C; this is what
to know.

- **The box's left and right edges are the mouse-face rule.**
  `pgtk_draw_glyph_string` adds them when `hl == DRAW_MOUSE_FACE`,
  regardless of the neighbours' boxes; the mode line's own face is
  boxed, so the ordinary rule drew only top and bottom. `draw-mode-line!`
  tracks which prepared pieces are lit and passes the edges at the lit
  run's boundaries.
- **`format-mode-line` now tags every element's output with
  `mode-line-elt-no`**, as Emacs's `store_mode_line_string` does (the
  counter increments on entry to `display_mode_element`). The hover run
  walks `mouse-face` *and* this property, so it stops at the element's
  edge - Emacs gets the same result because each element is its own
  string object in the glyph row.
- **A `%` construct's properties go on its constructed text, not on the
  field padding** (inherited before padding, not after): Emacs's padding
  gets only the elt-no marker, so `%12b`'s padding is not part of the
  name's target.
- Test traps: `member`, not `memq`, to find a recorded `(x cells left?
  right?)` call. And a `set-face-attribute` on `mode-line` does not reach
  `mode-line-active`, whose `:inherit mode-line` comes from the defface
  spec - the box test sets a dark `*frame-background-mode*` and
  recalculates the faces instead, which is what puts the box on a Gtk
  frame too.

## Verified

All **78** suites pass (`mode-line-tests` 51, `coding-tests` 76,
`tty-editor-tests` 348 unchanged), the touched libraries compile with
no warnings, and `imports.scm` is regenerated (101 libraries, 3768
names). `tools/pty-check.py` cannot click - a terminal has no mouse -
so the dispatch is exercised by the suite through `dispatch-key`, which
is exactly what both front ends call for one event; the Gtk path's only
extra step is `posn-at-x-y`, which the suite uses to build each event.

## Still open, named in DEPARTURES.md

The **mode-line menus** (major mode, minor modes, the position menu):
they need `get_keyelt`'s `:filter` evaluation and
`read_char_x_menu_prompt`'s popup rule, and the list of every function
and what each waits for is in DEPARTURES.md. **`help-echo` display** is
the other: the properties are carried, `tooltip.el`/`x-show-tip` are
not ported, so hovering says nothing yet.

# Handoff — the help echo and tooltips (2026-11-20)

Chris: *"real emacs has tool tips as you hover so you can see what that
function does."* The `help-echo` properties the mode-line work had
carried were displayed by nothing; they are now displayed, and the chain
is Emacs's own, bottom up:

```
note_mouse_highlight (xdisp.c)  -> finds help-echo (overlay, text property,
                                   mode-line/tab-line string, or the window's
                                   mode-line-default-help-echo fallback)
  -> show_help_echo (keyboard.c:2259)   -> show-help-function
     = tooltip-show-help (tooltip.el)   -> a delayed timer
       -> tooltip-show -> x-show-tip -> display-show-tip (a dispnew generic)
          -> pgtk.scm: Gtk's tooltip object with OUR custom label
```

What landed, in one line each:

- **`keyboard.scm`**: `show-help-echo` (string / function / form,
  `safe_calln`-style), `help-echo-substitute-command-keys` with the
  substitution seam `*help-echo-substitute-function*`, the
  `*show-help-function*` parameter, and the `mouse.fixup` seam
  `*mouse-fixup-help-message-function*`. Installs
  `*show-help-echo-function*` at the end of the file for `xdisp.scm`,
  which is below it.
- **`xdisp.scm`**: `help-echo-at` (the three places Emacs looks),
  `string-help-echo-at`, `text-help-echo-at`,
  `window-mode-line-help-echo` (`w->mode_line_help_echo`), the
  `mode-line-default-help-echo` function and its defcustom
  `*mode-line-default-help-echo*`, `%help-echo-previous`, and the call
  from `note_mouse-highlight`.
- **`tooltip.scm`** (new): the whole of `tooltip.el` - the mode, the
  five delays and the parameters, the timeout machine, `tooltip-show`,
  `tooltip-hide`, the echo-area half, `x-show-tip`/`x-hide-tip`, and the
  debugger helpers that need no processes.
- **`dispnew.scm`**: `display-show-tip`/`display-hide-tip` generics.
- **`pgtk.scm`**: the Gtk method - a custom `GtkLabel` (wrapping off)
  handed to Gtk's tooltip object through `query-tooltip`, plus
  `gtk_widget_trigger_tooltip_query` so the tip appears at Emacs's
  delay rather than Gtk's hover schedule.
- **`mouse.scm`**: `mouse-fixup-help-message` (the "mouse-2" -> "mouse-1"
  rewrite over links) and its seam install.
- **`frame.scm`**: `mouse-pixel-position`; `current-message`'s seam now
  answers nil for a cleared message.
- **`timefns.scm`**: `time-since`; `lisp-time-arguments` handles a
  non-integer time exactly.
- Both front ends import `(schemacs tooltip)` (preloaded in Emacs,
  and its load is what turns the mode on); `loadup.scm` lists it;
  `imports.scm` is regenerated.

## The traps, in the order they cost time

0. **The tooltip is on Gtk's tooltip object with a custom label, not
   `gtk_widget_set_tooltip_text`.** The plain text tooltip is what the
   PGTK C does, but Gtk's default tooltip label wraps, and a wrapped
   multi-line tooltip gets sized before the wrap is measured - Chris
   saw the last line clipped. Emacs's own non-PGTK GTK code solves this
   by building a label with `gtk_label_set_line_wrap (FALSE)` and
   handing it over with `gtk_tooltip_set_custom` (`qttip_cb`,
   `gtkutil.c:837`); that is the shape here. If tooltips ever stop
   appearing, check the `query-tooltip` handler is connected (the area
   and the outer window) and that it returns `#t`.

   **The label needs `g_object_ref`, or the editor dies on the second
   hover.** Gtk parents the custom label into its tooltip window and
   drops its reference when that window goes; guile-gi's proxy is not a
   strong reference, so the label was freed under the proxy and the next
   query raised `gtk_label_set_text: assertion GTK_IS_LABEL (label)
   failed`, then `g_object_unref`/`instance with invalid (NULL) class
   pointer` - Chris hit exactly this while mousing over the mode-line
   items. Emacs pins its label with `g_object_ref` (`qttip_cb`,
   `gtkutil.c:861`); guile-gi exposes no ref, so `pgtk.scm` calls it
   through `dynamic-func` (libgobject). The ref is never dropped, one per
   display, as in Emacs. Reproduced and fixed under broadway: three
   show/hide cycles, zero Gtk criticals, editor alive.

1. **`concat` and `when`.** `mode-line-default-help-echo` builds its
   answer with `concat`, and Elisp's `concat` ignores nil. A `when`
   that does not fire answers the *unspecified* value, which `concat`
   rejects ("Wrong type argument: sequencep"). Every piece is an `if`
   with `#f` now. This is the `when`-as-a-value trap the earlier
   handoffs name, met inside `concat` for the second time.

2. **A function-valued `help-echo` is the procedure here.** `bindings.el`
   writes the *symbol*, and Emacs's `FUNCTIONP` resolves it through the
   obarray. There is no function obarray in this tree, so
   `mode-line-modified`/`mode-line-remote` store the procedure, and
   `show-help-echo` calls a procedure value. `mode-line-tests` pins it.

3. **`define-minor-mode` does not run a mode's body at load.**
   `tooltip-mode`'s `show-help-function` install happens because Emacs's
   defcustom `:set` calls the mode during `:initialize`. The macro here
   drops `:set`/`:initialize`, so `tooltip.scm` ends with
   `(tooltip-mode 1)`. Any future global mode with `:init-value t` whose
   body installs something needs the same call.

4. **`current-message` must answer nil, not "".** `tooltip-show-help-non-mode`
   and `tooltip-hide` distinguish "no message" from "a message"; the
   frame's slot holds `""` after a clear, so the seam translates it.

5. **Inexact times.** `(float-time)` is what `tooltip-hide-time` stores;
   `time-since`/`time-subtract` used `(cons time 0)` for a number and
   then exact arithmetic, which raised on `(ash 1.7e9 -16)`.
   `lisp-time-arguments` now splits a non-integer into exact
   seconds+picoseconds.

## How to check it live

- **In a terminal editor**: nothing hovers, because there is still no
  mouse reporting - the echo-area half is all a tty would use.
- **On a Gtk frame under broadway**: drive the *chain*, not the popup.
  Build a frame, `(note-mouse-highlight f col row)` from the REPL, wait
  past the 0.7s delay, then read the widget's tooltip text back:
  `(widget:get-tooltip-text (pgtk-window (frame-output f)))` - it should
  be the help string the item names, and `#f` after the pointer leaves.
  Broadway has no pointer, so Gtk's popup itself cannot be shown or
  inspected there; `gtk_window_list_toplevels` will not contain it.
- **The recording display** in `tooltip-tests.scm` covers
  `tooltip-show`'s half without Gtk.

## Not carried

`x-pre-popup-menu-hook`, `menu-or-popup-active-p` (NS), the tooltip
process helpers (no subprocesses), `tooltip-reuse-hidden-frame` and the
tooltip *frame* of the non-system path, `message-truncate-lines`, and
help-echo on images/fringes. DEPARTURES.md's 2026-11-20 section has the
reasons.

# The mode-line menus, the tooltip crash and the stuck drag (2026-11-20)

Three pieces of work in one session: the mode name's and the lighters'
menus (`bindings.el:571-596`, `mouse.el:222-330`, `help.el:1293-1400`),
the Gtk tooltip's lifetime, and a key-lookup departure that made a
mode-line drag unstoppable. DEPARTURES.md's 2026-11-20 section has the C
and every named departure; this is what the next session needs.

## The menus

- **A press on the mode name now pops its menu** (`mouse-menu-major-mode-menu`),
  a press on a lighter pops that mode's (`mouse-minor-mode-menu`), mouse-2
  on the name runs `describe-mode`, mouse-2 on a lighter runs
  `mode-line-minor-mode-help`, and mouse-3 on either pops the toggles
  menu (`mode-line-minor-mode-menu`). Emacs binds these through
  `(menu-item ... :filter ...)` and the lookup has no filter arm here, so
  the two presses bind commands that call the C's own builders -
  `mouse-menu-major-mode-map` and `bindings--sort-menu-keymap`.
- **`mouse.scm` cannot import `menu-bar.scm`.** `menu-bar` imports
  `isearch` -> `help-fns` -> `help` -> `mouse`, so `popup-menu` and
  `menu-bar-edit-menu` reach `mouse.scm` through two parameters -
  `*popup-menu-function*` and `*menu-bar-edit-menu*` - which
  `menu-bar.scm` installs as it loads. If a mode-line menu ever does
  nothing in a build, check those installs first.
- **Each lighter is its own run.** Emacs's redisplay keeps one string
  object per lighter, so `posn-object` answers `" Fill"` and not the
  group; this renderer flattens the line, so each lighter carries a
  `mode-line-lighter` index and `string-property-run-at` /
  `string-mouse-face-at` stop at it. The bug that surfaced this:
  `apply string-append` drops text properties - use `concat`.
- **`*minor-mode-alist*`'s default is bindings.el's four entries again.**
  The missing `(auto-fill-function " Fill")` is why the Fill lighter had
  never appeared; the ` Fill` and ` Ovwrt` strings are what the click
  and the completion table compare against.
- **The `:button` toggle forms name this tree's readers**
  (`buffer-overwrite-mode`, `font-lock-mode-on?`,
  `buffer-auto-fill-function`), because `menu-item-eval-property`
  evaluates in the ambient module and a minor mode's command and
  variable cannot share a name here. A test that evaluates one must
  import the reader **and** `current-buffer`.
- `describe-minor-mode` and its two directions are in `help-fns.scm`
  (placement departure: they call `describe-function`), and the
  completion/lookup pair is in `mouse.scm` beside the mode-line
  machinery. `C-h` has no key for them; they are M-x only, as in Emacs.
- **Tests**: `mode-line-tests.scm`'s `schemacs_editor_mode_line_menus`
  group (73 passes in file) pins the maps, the help strings, the
  per-lighter runs, the press-to-menu path with a recording popup, the
  Help item through a stubbed `*describe-function-function*`, the
  sorted toggles menu, the toggle's evaluated reader, and the
  `menu-bar-edit-menu` fallback. `tools/pty-check.py` cannot click
  (a terminal has no mouse), so the suite's `dispatch-key` is the
  end-to-end path.

## The tooltip crash (Chris's Gtk-CRITICAL paste)

`gtk_label_set_text: assertion 'GTK_IS_LABEL (label)' failed`, then
`g_object_unref`/invalid class pointer. Gtk parents the custom tooltip
label into its tooltip window and drops its reference when that window
goes; a guile-gi proxy is not a strong reference, so the label was freed
under it. Emacs pins its label with `g_object_ref` (`qttip_cb`,
`gtkutil.c:861`); guile-gi exposes no ref, so `pgtk.scm` calls it through
`dynamic-func` and never drops it - one label per display, held on the
display record. Verified under broadway: three show/hide cycles, zero
criticals, editor alive.

## The stuck drag was a lookup departure

Chris: mousing over the read-only flag showed the box and the drag
cursor, clicking went into drag mode and stayed there until C-g.
`%unbound-mouse-reduction` treated the release as "drop" because the
lookup never found the item's own `[mode-line mouse-1]`: the command
loop's modal lookup looked the event up **one map at a time**, where
Emacs's `read_key_sequence` hands `follow_key` one `current_binding` - a
**keymap list** - and `access_keymap_1` collects a prefix answer from
every map in it. A release the transient map did not bind therefore had
to fall through to the item's map, and did not. `modal-lookup-state-lookup`
now passes the whole list to one `keymap-lookup`; the step's
command-or-prefix test is `keymapp` (not `keymap-type?`), because a
prefix answer to a list is `(keymap M1 M2)` - a list, not a record.
The regression test is `mode-line-tests.scm`'s
`schemacs_editor_mode_line_press_release` group, seen failing with the
old per-map walk.

**The box and the drag cursor over the remote flag are Emacs's own** - it
has no `local-map` (`xdisp.c:36790-36810`), so the mode line's drag
handle shows through. Clicking it now runs the drag's release and the
drag ends; before the fix the transient map could not be popped.

## Still open

- `mode-line-compact` (and with it `describe-minor-mode-from-indicator`'s
  disambiguation arm) is not ported.
- The mode-line `mouse-face` run is per element now; a *theme* that sets
  `mode-line-highlight` differently from `mode-line` still shows on the
  text, not in the box edges, unless the box is in the face - the
  existing note stands.
- `tooltip-tests.scm` and `mode-line-tests.scm` are in
  `tools/run-suites.py`; the pty battery on this tree is **100/100**
  (the run after the mode-line menus landed).

# `mode-line-position` and the mode line's variable registry (2026-11-20)

Chris chose "port it whole" for the last remaining mode-line menu. The
default mode line now reads like Emacs 31.1's - `All L1`, not the old
`-- L1 C0` - because the position item is Emacs's construct, with the
percentage constructs and the three visibility modes under it.
DEPARTURES.md's same-day section has the C and every named departure.

## What to know before touching it

- **A construct's symbol is now evaluated.** `format-mode-line`'s
  `(SYMBOL THEN ELSE)` conditional used to take its ELSE arm
  unconditionally (the test's value was never read); it now reads the
  symbol through `mode-line-symbol-value`, and a bare symbol element is
  evaluated and processed as a construct - both are Emacs's
  `display_mode_element`.
- **`mode-line-symbol-value` reads three registries**: the buffer's
  slots, the global default table, then a `define-custom` reader - tried
  under the bare name and under the tree's starred spelling, because a
  construct says `mode-line-position` and `define-custom` records
  `*mode-line-position*`. A plain `define`d variable is *not* reachable;
  that is the same gap `describe-variable` has, and the reason the five
  position variables are `define-custom`s.
- **`define-minor-mode` now emits `(unless (default-boundp MODE)
  (set-default MODE INIT))` for a `:global` mode** - Emacs's `defvar`
  rule. It is a macro change: **recompile every library that uses it**
  or the stale `.go` keeps the old expansion (`bound?=#f` is the
  symptom). `default-boundp` had to be imported into `easy-mmode.scm`
  for the template to resolve.
- **The percentage constructs are `%o`, `%p`, `%P`, `%q`**, with
  `percent99` (`(d - 1 + 100n) / d`, capped at 99) and
  `window-bottom-position` (`BUF_Z - window_end_pos`; our `end-pos` is
  stored as a distance from the text end, so the text's Z is added
  back). A fully visible buffer prints `All`; the top of a taller one
  prints `Top`; the end prints `Bottom`.
- **`line-column-mode-menu` is popped by `mode-line-line-column-menu`**,
  a command in `mouse.scm` bound in `mode-line-column-line-number-mode-map`
  - the same stand-in the other two mode-line menus use, because the
  lookup has no menu-prompt path.
- **The pty battery's init turns `column-number-mode` on.** Several
  checks read the *column* off the mode line as their point oracle, and
  the default no longer shows it; with the mode on the line reads
  `(LINE,COL)` and those checks wait for `(1,15)` / `(1,6)` / `(1,0)`.
  `tty-editor-tests`'s two column tests wrap their assertions in
  `(column-number-mode 1)` / `(column-number-mode -1)` for the same
  reason.
- **The tree's whole-mode-line test strings changed**:
  `-UUU:**- alpha.txt   All L1     (Fundamental)` (one fewer space
  before `All` than the old `" -- "` spelling - the construct starts at
  the position with no leading space).

## Still open

- `mode-line-collapse-minor-modes` (Emacs 31.1's lighter hiding) and
  `mode-line-invisible-mode`.
- `%s` (the process construct) and `%[`/`%]` (recursion depth) are still
  printed as they stand; there are no processes and no recursive
  minibuffer edits to report.
- A `risky-local-variable` marking is not carried; there is no
  `risky-local-variable-p`.

## Tests

`mode-line-tests.scm`'s `schemacs_editor_mode_line_position` group (86
passes in file): the construct's exact answer in a fully visible buffer
(`"All L1   "`, and `"All (1,0)    "` with Column Number mode on), the
`All`/`Top`/`Bottom` words and `%q`'s `100%` tail on a 100-line buffer,
`percent99`'s arithmetic, the map's press binding, and the three menu
toggles' display order and initial states.

## `popup-menu`'s arity (2026-11-20, same session)

Chris: *"clicking on the mode in the menu bar: Wrong number of arguments
to #<procedure popup-menu (menu position prefix from-menu-bar)>"* - the
mode-line menus' seam calls `(popup-menu menu event)`, and the procedure
had been defined with all four of Elisp's arguments **required**. It
takes a rest parameter now, `(menu . rest)`, reading position, prefix and
from-menu-bar the way the tree reads every optional argument. If a menu
"does nothing" or raises like this, check the arity of what the seam
points at first: the recorder in `mode-line-tests` accepted any number of
arguments, so the suite could not see it, and only `menu-bar-menus-tests`
(a real `popup-menu` with a #f map, which short-circuits before
`x-popup-menu`) pins it.

## The popup, the right margin, the scroll bar, and the coding-system
## item (2026-11-20, same session)

Chris's four reports, and what each turned out to be (DEPARTURES.md has
the C):

1. **The menu popped at the top-left.** `menu-show`'s Gtk method was
   handing cell coordinates to `gtk_menu_popup_at_rect`, which wants
   pixels. It converts with `cell-x`/`cell-y` now.
2. **The mode line / tab bar / tab line stopped a few pixels short.**
   The grid is whole cells; the leftover strip kept the frame's
   background. `%pgtk-write-run` and `clear-end-of-line!` extend the run
   that ends at the grid's last column to the pixel edge - Emacs's
   clipped final space (`display_mode_line`'s "Fill up with spaces").
   Verified live under broadway at a 741-pixel-wide window (cell 9):
   the mode-line row's pixel at x=740 is the mode-line background.
3. **The scroll bar was inset.** Emacs puts it at the window's *pixel*
   right edge; ours sat at the last column edge. The Gtk scroll-bar
   method moves a right-hand bar whose right edge is the frame's last
   cell edge by the remainder. Verified: margin-start 723 + width 18 =
   741 at a 741-pixel allocation.
4. **The `U` was not clickable.** `%z` now carries
   `mode-line-coding-system-map` (mouse-1 describes, mouse-3 sets),
   `mouse-face`, and `mode-line-mule-info-help-echo`, as
   `bindings.el:74-88`/`:216-220` do. `describe-coding-system` is in a
   new `mule-diag.scm` (mule-diag.el's coding-system half), its output
   byte-identical to Emacs 31.1's for `utf-8-unix`, `no-conversion` and
   `utf-8`. `mule-cmds.scm` installs the second seam
   (`*set-buffer-file-coding-system-command*`) so mouse-3 can call the
   command *interactively* (the prompt is the point).
   `mode-line-tests`' `mode_line_coding` group and the new
   `mule-diag-tests.scm` pin it.

**Also**: the pty battery's mode-line row selectors used the tree's old
`-- L1 C0` spelling in *nine* places (a `MODE_LINE_RE` now matches
Emacs's shape - `Top L1`, `All (1,3)`), and `mode_line_has_line` accepts
both the ` L<n>` and `(n,col)` forms. A full battery on the tree before
the selectors were fixed gave 89/100 with every failure a "0 windows"
count: the checks were counting mode lines by the old spelling, not
seeing a real fault.

# The save prompt, `map-y-or-n-p`, and `yes-or-no-p` (2026-11-21)

Chris, quitting with `C-x C-c` on a modified buffer: the save question
had no blinking cursor at the end, a different option list, and after
`n` the exit-anyway prompt only appeared on the next keypress.

**The cause was one primitive that was never ported**: `save-some-buffers`
spelled its own single-key question with `read-char-from-minibuffer`
instead of asking through `map-y-or-n-p` (`map-ynp.el`), so nothing had
Emacs's prompt, its answers, or its echo. All of it is in now -
`map-y-or-n-p`, `save-some-buffers` in files.el's shape,
`save-some-buffers-action-alist`, `save-buffers-kill-emacs`,
`save-window-excursion`, `run-hook-with-args-until-failure` and a
re-ported `yes-or-no-p` (it had taken a *frame*; Emacs takes one
argument). DEPARTURES.md's 2026-11-21 section has the C for each rule
and every named gap; the ones worth knowing before touching it:

- **`quit-flag` is raised by Emacs's evaluator, not by the setter.**
  `map-y-or-n-p`'s `quit` answer is `(setq quit-flag t)` + `try-again`,
  and the quit is signalled by `maybe_quit` in `eval_sub` on the *next
  call* - before the re-ask's own `(setq quit-flag nil)`. Scheme has no
  such check, so `step` calls `(maybe-quit)` at its top; without it C-g
  in a `map-y-or-n-p` question asks again for ever (measured: a hang).
- **`query-replace-map` is a plain variable** (a keymap made at load),
  and `unread-command-events` **is a parameter** - both were read the
  wrong way in the first draft, and the first gives "Wrong type to
  apply: #<<keymap-type> ... *query-replace-map*>".
- **`read-from-minibuffer`'s argument order is PROMPT INITIAL KEYMAP
  HISTORY DEFAULT** - a history passed in the DEFAULT slot makes an
  empty answer *be* the value, which surfaced as "expecting string: #t"
  from `read-minibuffer-1`'s history add.
- **HIST `t` means "do not record"** (`read-from-minibuffer`'s
  docstring). It is stored as `#t` and every reader asks `history?`
  first, which is Emacs's own `(listp history)` test.
- **The answers are events**: the action alist's keys are the one
  element inside `(kbd "M-~")`/`(kbd "C-r")`/`(kbd "C-f")`, because
  `map-y-or-n-p` wraps each in a vector, as the C wraps a character.
- **`save-buffers-kill-terminal` and `save-buffers-kill-emacs` take
  `&optional` arguments**: written as rest parameters, or
  `handle-delete-frame`'s `(save-buffers-kill-terminal)` is an arity
  error.
- The prompt's option list is Emacs's, less `d` (diff needs
  subprocesses): `Save file X? (y, n, !, ., q, M-~, C-r, C-f or C-h)`.
  Measured on Emacs 31.1, and `test/core/map-ynp-test.scm` pins the
  string.
- `@@ (schemacs core map-ynp)` is not in `imports.scm` (only
  `(schemacs editor ...)` libraries are), so M-: cannot call
  `map-y-or-n-p`; every command that uses it imports it. The new suite
  is in `tools/run-suites.py`.
- **`yes-or-no-p` takes one argument now** (Emacs's); the two call
  sites that still passed a frame (`find-alternate-file`,
  `revert-buffer`) signalled inside `string-length` and their commands
  died silently behind the command loop's guard - `revert-buffer`'s pty
  check is what found it. When a signature changes, grep every caller;
  the battery is the net that catches the ones the suites miss.
- Verified on the settled tree: all suites pass and
  `tools/pty-check.py` is **100/100**.

# The region, the row's tail, and the popup's unmap (2026-11-21)

Chris's four reports - a region stopping at the line end, blank lines in
a region unpainted, a region leaking into the next window, and other
windows' regions being forgotten - were one departure: the region was a
face merged by the run walk, where Emacs 29+ keeps **one overlay per
window**. `redisplay--update-region-highlight` and friends are in
`simple.scm` now; the overlay lives in
`window-parameter 'internal-region-overlay`, carries `face region`,
`priority (nil . 100)` and the `window` property, and is filtered by
`overlay_matches_window` in `attrs-at-buffer-position` and in the
overlay-string walk. `extend_face_to_end_of_line`/`extend_face_id` are
ported, so a row's tail is painted when the face at the line's **end**
says `:extend` - including a blank line, whose "face at the end" is the
newline's. DEPARTURES.md's 2026-11-21 section has every rule, the
measured three-window table and the named departures.

## What to know before touching it

- **The default shows only the selected window's region.** Measured on
  Emacs 31.1: setting a region in w1 and then selecting w2 leaves w1's
  overlay *deleted*; returning to w1 recomputes it from w1's
  `window-point` and the **shared** mark. `highlight-nonselected-windows`
  t is what makes all windows show `[window-point, mark]` at once. The
  user's "Emacs remembers the regions" is that setting (or the stale
  pixels Emacs leaves in a window it does not repaint); this tree
  reproduces the *state* in both settings.
- **Only the selected window shows a region.** `redisplay--update-region-highlight`
  (`simple.el:7332`) keeps a window's overlay only when
  `highlight-nonselected-windows` is true, or the window is selected,
  or the selected window is the minibuffer and this is the window it
  was entered from; otherwise it deletes the overlay. `render!` runs
  the hook for every window (it repaints every window every frame, so
  it is always in the C's all-windows case), and moving between windows
  therefore removes the highlight from the one left behind. An earlier
  pass made non-selected windows "remember" their regions on the
  strength of a user report that was later withdrawn; **the code is the
  authority and that policy is reverted**. Selecting a window again
  recomputes `[window-point, mark]`, as the hook does. With
  `highlight-nonselected-windows` true every window keeps its own
  `[window-point, mark]`.
- **The backends clip to the window's body rectangle.**
  `write-glyphs!`/`clear-end-of-line!` in `term.scm` and `pgtk.scm` stop
  at `window-body-left + window-body-width` (the frame's last column
  when there is no window - `update-window!` writes a frame-matrix row).
  Without it a row wider than its window painted into the window beside
  it; the row builder's clear limit is clamped too. On the terminal,
  `ce` is used only when the clear reaches the frame's last column,
  because `ce` wipes the whole terminal line.
- **The GUI fill is space glyphs in the row, not a stretch glyph**
  (Emacs's `append_stretch_glyph`): this tree's glyph is a cell. The
  row's own vector is reused, so no allocation. The GUI skip is "the
  extend token is the default face's" rather than Emacs's
  background/box/underline test - named in DEPARTURES.
- **The mono inverse-video allowance is gone.** Emacs's region defface
  has no `:extend` on its mono branch and a vt100 paints only the
  characters and the newline's own cell; the faces-tests use an
  **8-colour** display wherever they ask for an extension.
- `window-matrix-valid?` no longer asks about the region pair: moving
  the overlay raises `OVERLAY_MODIFF`, which `window-outdated?` reads.
- `(mark)` answers an integer, as Emacs's does (measured:
  `(markerp (mark))` is nil there too); `mark-marker` is the marker.

## The popup warning

`Gdk-WARNING: Tried to unmap the parent of a popup` came from the
after-redisplay drain dispatching a menu selection's queued keys
*inside* the popup's own Gtk loop, so the item's command rebuilt the
menu bar while Gtk was unmapping the popup attached to it. Two pieces
of the C are now ported: `popup_activated_flag`
(`*pgtk-popup-depth*`, a `dynamic-wind` around the popup; the drain
refuses to run while it is non-zero) and
`menubar_selection_callback`'s `gtk_events_pending` flush before the
keys are queued. Not reproducible on demand; the check is structural.

## How it was measured

- Emacs 31.1 in a pty: three windows on one buffer, a dump of each
  window's `internal-region-overlay` printed with
  **`external-debugging-output`** (stderr). A temp *buffer* would set
  `windows_or_buffers_changed` and invalidate the very state being
  measured, and Emacs 31 has **no `open-file`** for a file port.
  `M-:` deactivates the mark, so drive regions with keys only, and bind
  the dump to a key.
- Emacs 31.1 in **tmux** (`-L` its own socket): `capture-pane -p -e`
  gives the screen with SGR, which is how the region's blue cells per
  window were counted - a pty byte stream is not a screen.
- The live Gtk editor: `window-parameter` dumps for the overlay state,
  and `pgtk-write-screenshot!` + a pixel scan for the painting (region
  `(238,220,130)`; the cursor cell is the one non-region cell at point).
- The blank line inside a region was verified with a region spanning
  lines 1-6: its row is a full-width run of the region colour, and each
  line whose break is in the region is full width; the last line stops
  where the region ends.
- The final rule was driven live: three windows, a region set in each in
  turn, then only the last-selected window has a live overlay - the
  others' are deleted (`(#f #f #f)` from `(overlay-buffer o)`) - and the
  screenshot's region pixels are inside that window's body alone
  (x 567..638 in a body spanning 558..719; nothing outside it).

### A direct check of the clip

With the Gtk backend, `write-glyphs!` was handed a row of **43 glyphs**
at the left window's body-left (`window-body-width` is 38) and the
surface scanned at that row: ink in cells 0-37, **none from cell 38 on**
- the scroll-bar columns and the next window untouched. That is the
guarantee the user's truncated-line report was missing.

## Still open

- **Incremental redraw remains the real gap.** Emacs's visible "region
  memory" is partly glyph matrices it has not rebuilt; this renderer
  rebuilds them every frame, so its behaviour is reproduced by the hook
  policy above rather than by stale pixels. `try_window_id` is still
  the named project.
- The GUI extend skip's simplification (background equal to the frame's
  plus no box/underline, rather than "the default token").
- `w->last_mark` is recorded but no text conversion reads it.

## Verified

All 81 suites pass on the final tree (`tty-editor-tests` 352,
`faces-tests` 34, the five region tests among them) and the tree
compiles with no new warnings. `tools/pty-check.py` on the final tree
gave **97/100** under the machine's own load: `quoted-insert`,
`completion-ui` and `metahelp` failed, and each passed **3/3 when rerun
alone** on the same tree - the battery's documented between-key/startup
race class (each failure's screen showed an editor that had not yet
processed the key). The region, scroll, save, truecolor,
completion-window, narrow and resize checks all passed in that run.
# Narrowing across windows, `$`, and the first cell of a blank line
# (2026-11-21, the pass after the region work)

Chris's four questions after using the region code. DEPARTURES.md's
2026-11-21 section has the C and the full account; in one line each:

- **A narrowing moves every window on the buffer onto the narrowed
  text.** Not through a clamp: `redisplay_window`'s fast paths are all
  guarded on the window's start lying in `[BEGV, ZV]`, so an
  out-of-range start falls through to `recenter:` (`xdisp.c:21158`),
  which seats the iterator on **PT** (the buffer's point, `:21165`),
  centers half a window back, and writes `w->start` (`:21274`).
  `display-window!` clamped the start to `point-max` and laid out from
  there, which drew blank rows; it calls `recenter-window-on-cursor!`
  at the buffer's point now. Regression:
  `tty-editor-tests.scm`'s "narrowing brings every window on the
  buffer to the text" (two windows, narrow [800,900], the other
  window's start is 800 and 800 is visible), seen failing before.
- **Truncation vs wrapping is `init_iterator` (`xdisp.c:3413`), shared
  by both front ends** through `window-truncates-lines?`
  (`indentc.scm`). A full-width window wraps; a partial one narrower
  than `truncate-partial-width-windows` (50) truncates; `truncate-lines`
  and hscroll also truncate. A full-width 80-column tty window wraps;
  the ~39-column windows after `C-x 3` truncate - geometry, not a
  front-end difference.
- **`$`/`\` are `produce_special_glyphs`'s truncation/continuation
  glyphs in the DEFAULT face** - `insert_left_trunc_glyphs` sets
  `face_id = DEFAULT_FACE_ID` (`xdisp.c:23923`) - so they are not
  region-coloured in Emacs either, left `$` included. We draw both with
  `(face->attribute 'default)`.
- **A blank line inside a region is filled from column 0.** The one
  cell that can still look unpainted is the cursor's, and that was a
  real bug of ours, now fixed - see "The cursor's glyph is the row's"
  below.

## The cursor's glyph is the row's, not the buffer's (2026-11-21)

Chris, again: *"if I put a mark, then move the cursor up and it's
painting the selected region, it doesn't paint the first character on
an empty line"*, and then *"it works when moving down, just not moving
up"*. The asymmetry is the diagnosis: Emacs's
`redisplay--highlight-overlay-function` does not move an overlay whose
bounds are unchanged (`simple.el:7294`), so the redisplay that *grows*
the region rebuilds every row and masks the damage; the next redisplay
with nothing changed skips every row (fresh window), and the cursor's
own erase is the only paint on its cell. Moving up, that cell is the
blank line at the region's start; moving down it is outside the region.

Two omissions, both `xdisp.c`'s:

1. **`append_space_for_newline`** (`:24191`, called at `:26597`) was
   missing. Every row now ends with a space glyph carrying the
   **newline's face** - region when the blank line is in the region -
   and the default face at `ZV` (the `(it, true)` call at `:26083`).
   `build-row!` appends it when the row reaches the line's end (not
   `more?`, not `truncated?`), before the fill, so it is the row's last
   glyph for `extend_face_id`.
2. **`cursor-glyph` read the buffer**, and at the end of a line its
   line string has no such character, so it answered `" "` with the
   *default* face; `erase_phys_cursor` then repainted the cell from
   that. Emacs's `get_phys_cursor_glyph` (`:37894`) takes the glyph
   from the **row**, and `draw_phys_cursor_glyph` (`:35105`) redraws it
   in its own face. `xdisp.scm`'s `phys-cursor-glyph (row column)` is
   that: the glyph at `column - (glyph-row-x row)`, `$`/default for the
   one cell an hscrolled row gives up, a default space past the row's
   glyphs.

Tests: `pgtk-tests.scm`'s "the cursor on a blank line keeps the region
in its cell" - two Gtk renders with `dn:set-windows-or-buffers-changed!
#f` between them (the steady state), sampling the cell's interior; it
fails `(255 255 255)` under the old glyph source and passes region
`(238 220 130)` now. `tty-editor-tests.scm`'s "a blank line's row
carries the newline in the region's face" pins the row glyph and the
fill. Both were seen failing with the fix reverted. All 81 suites pass
(`tty-editor-tests` 354, `pgtk-tests` 119) and `tools/pty-check.py` is
**100/100** on this tree. **A running editor keeps its code** -
restart before looking.

All 81 suites pass after the change (`tty-editor-tests` 353), and
`tools/pty-check.py` is **100/100** on this tree, run on its own - the
`narrow` check (which drives `C-x n n`) among them and green.

# The regexp engine and the C mode — the plan, and step 1 (2026-11-21)

Chris approved a full port of `src/regex-emacs.c` "including categories
and everything", which is the prerequisite for a faithful `cc-mode`.
This is the plan, the measurements it rests on, and what has landed.

## Why: the measurements

cc-mode is regexp-pervasive, not a character parser: Emacs 31.1 on
`src/minibuf.c` (2,761 lines) with `looking-at`/`re-search-*`/`string-match`
instrumented:

| operation | time | regexp calls |
|---|---|---|
| font-lock whole buffer | 0.85 s | 377,768 `looking-at` + 20,014 `re-search-forward` |
| font-lock 3 lines (a jit-lock keystroke) | 1.6 ms | 107 + 97 |
| `c-indent-line` (TAB) | 2.1 ms | 485 + 80 |

The constructs the C mode needs that glibc/our translator does not do:
`\=` (refused today: `(string-match "\\(\\=\\|x\\)" "x")` raises),
buffer-scoped `` \` ``/`\'` inside searches, and **leftmost-first**
alternation. Measured in Emacs on "ab" at point 2:
`(looking-at "\\(\\=\\|b\\)")` matches the empty `\=` branch
(`match-end` 2), where POSIX ERE takes the longer `b`. `cc-langs.el:1187`'s
`noncontinued-line-end` and `cc-langs.el:3630`'s
`c-stmt-block-only-keywords-regexp` put `\=` on the C path.

Guile microbenchmarks that say a Scheme engine is affordable if it is a
compiled opcode VM over the buffer (not an interpreter over patterns):
a hand-written symbol scan at every start of a 59-char C line **5.0 µs**
against **64.2 µs** for glibc `regexp-exec` at every start; one symbol
match **111 ns** against 903 ns; compiled function call 8 ns, fixnum
`cond` 5 ns, u32vector scan 3.9 ns/char. Projection: 200-600 regexp
calls a keystroke × 0.05-1 µs = 0.01-0.6 ms.

## Steps 1 and 2, landed: bool vectors, categories, case tables

See DEPARTURES.md's two 2026-11-21 sections. `(schemacs data)`
has `make-bool-vector`/`bool-vector` and data.c's operations over one
exact integer; `(schemacs category)` is `category.c` whole, with
`word-boundary-p`, the standard table and `char-script-table` (empty
until characters.el); `(schemacs casetab)` is `casetab.c`, with
`set-case-table`, the derived UP/CANON/EQV slots and the ASCII standard
table. `category-tests.scm` (20) and `casetab-tests.scm` (13), every
expectation Emacs's own, are in the runner; all **83 suites** pass.

## What remains, in the order it has to be done

1. **`casetab.sld`** (`src/casetab.c`) - `standard-case-table`,
   `set-case-table`, the `case-canon`/`case-eqv` extras the engine's
   `translate` reads (`search.c` passes `BVAR (current_buffer,
   case_canon_table)` when `case-fold-search`). The tree has no case
   tables today; casefiddle uses Guile's case conversions.
2. **`characters.el`'s data**: `char-script-table`, the category table's
   contents (`define-category`/`modify-category-entry` for the 178
   entries) and the case tables. Transcribing from a running Emacs is
   the project's method for data (charset maps, xterm's decode map);
   the *code* is ported.
3. **`regex-emacs.sld`** (`src/regex-emacs.c`, 5,790 lines): the opcode
   enum, `regex-compile` (`:1742`), `re-compile-fastmap`/`analyze-first`
   (`:2866`-`:3398`), `re-search`/`re-search-2` (`:3422`-`:3680`),
   `re-match-2`/`re-match-2-internal` (`:4096`-`:5720`) with the
   memoization layer (`memo_*`, `:4241`-...) and the mutual-exclusion
   fast paths. Operate on code points, not UTF-8 bytes: the text is a
   stored u32 code point per position, which removes the C's entire
   decode layer from the inner loop (named departure).
4. **Integrate into `(schemacs search)`**: `compile-pattern`,
   `looking-at`, `string-match`, `re-search-*`, `match-data`,
   `replace-match`, `save-match-data` - the engine replaces glibc and
   `%emacs-ere`/the 512-char window copies; keep the existing
   `search-tests.scm` time bounds as the performance gate and extend the
   500-case differential (`emacs -Q --batch`) to the full dialect.
5. **Then `cc-mode`**: cc-defs -> cc-vars -> cc-langs -> cc-engine ->
   cc-fonts -> cc-mode, and cc-cmds/cc-align/cc-styles for indentation.
   The regexp engine is not an alternative to the 43k-line port; it is
   its prerequisite.

## Step 3, started: `regex-emacs.sld`

The engine's data structures, opcodes, text/context abstraction and
character-class/charset objects are written in
`schemacs/regex-emacs.scm` and compile. The library is **not in
`loadup.scm` or `imports.scm` and is imported by nothing** until the
compiler, fastmap, searches and matcher are complete - it exports only
what is defined so far.

The representation decisions, all documented in its header:

- an instruction is a mutable vector `#(OPCODE ARG1 ARG2)`; jumps are
  **absolute instruction indexes** (the C's byte offsets are relative);
  `succeed_n`/`jump_n` counters live in the instruction's own vector and
  are mutated in place, as the C mutates its bytecode;
- text is code points (`<re-text>`: length + ref), so the C's UTF-8
  decode layer disappears; `buffer->re-text` takes the hoisted
  `store gpt gap base z`;
- a charset is a record of a 256-bit map, an inclusive range vector and
  the `RECC_*` class bits, tested by `re-charset-member-full?` in the
  C's order (bitmap, ranges, classes);
- `<re-context>` carries the syntax table, category table, case
  translate table, `\=`'s point, whether the text is a buffer (for
  `` \` ``/`\'` and `\=`), and the buffer position of the text start.

Next, in the C's order: the compile stack and instruction-buffer
helpers; the first tranche of `regex_compile` (literals, `.`, `^`, `$`,
groups, alternation, `* + ?` and intervals) together with the matcher
cases for exactly the opcodes it emits; then the charset/class tranche,
the syntax/category/word/`\=`/backref tranche, `re_compile_fastmap`,
`re_search` and the memoization layer, and finally the swap of
`search.scm` onto the engine. Each tranche's tests are a differential
against `emacs -Q --batch` (pattern, text, start, `case-fold-search` ->
match data), the harness `search-tests.scm` already uses.

# Handoff — the Emacs regexp engine, compiler and matcher (2026-11-21)

`(schemacs regex-emacs)` now compiles and matches Emacs's regexp
dialect. **Nothing imports it yet** - it is excluded from `loadup.scm`'s
session list and from `imports.scm` until `search.sld` moves onto it.
`DEPARTURES.md`'s 2026-11-21 section has the C and every departure;
this is what the next session needs.

## What is in the file

- the opcodes, the pattern buffer, the registers, `<re-text>`,
  `<re-context>`, the `RECC_*` classes, the `<re-charset>` object;
- `regex-compile` (the whole `regex_compile` switch) and
  `re-compile-pattern`, which returns the C's message or `#f`;
- `forall_firstchar`/`analyze_first`, the `<re-fastmap>` and
  `re-compile-fastmap`;
- the failure stack, memoization, `execute_charset`, mutual exclusion,
  `re-match-2` (the whole matcher) and `re-search`.

`re-search` and `re-match-2` take a `<re-text>` and a `<re-context>`;
both are exported, along with `re-compile-pattern`,
`re-compile-fastmap`, `make-re-fastmap` and `re-fastmap-ref`.

## Before touching it

- **Compile it, don't just read it.** At Guile 3.0.11's default
  optimization the library segfaults on the first `regex-compile` call
  unless the internal helpers are marked assigned (the `(set! main-loop
  main-loop)` block, with the comment). If the function is refactored,
  re-run a compiled smoke test first; the interpreter and `-O0` both
  hide the miscompilation.
- **`%insert-at!`'s rule is "the instructions that move, move their
  targets"** - see DEPARTURES.md. It is not "targets at or after the
  insertion point".
- **A `smart` jump's target names the instruction *after* the trailing
  `jump`** in this representation, so the jump it rewrites is at
  `TARGET - 1`. Writing at `TARGET` corrupts the instruction after the
  loop.
- **`forall_firstchar_all` takes a start position now**; passing 0
  where the C passes `p2` makes `mutually_exclusive_p` examine the
  whole pattern and can wrongly choose the keep-string loop.

## What is missing, in order

1. **`characters.el`'s data is in** (2026-11-21, later): six files
   under `schemacs/etc/` (categories, scripts, the four case slots),
   loaded by `category.sld` and `casetab.sld`. `\c`/`\C`, the script
   boundaries and Unicode case folding now match Emacs. The matcher's
   `WORD_BOUNDARY_P` was a real bug this exposed - it is a NAND
   (`!(both single-byte)`), not "both multibyte"; see DEPARTURES.md.
2. **Wire `search.sld` onto the engine**: `compile-pattern`,
   `looking-at`, `string-match`, `re-search-forward/backward`,
   `match-data`/`set-match-data` (with Emacs's trailing-nil trim),
   `replace-match`, replacing `%emacs-ere`/glibc and the 512-character
   search window. Keep `search-tests.scm`'s time bounds as the gate and
   extend the differential to the full dialect. Then remove the
   `(schemacs regex-emacs)` exclusion from `loadup.scm` and
   regenerate `imports.scm`.
3. **Then cc-mode** (`cc-defs` → `cc-vars` → `cc-langs` → `cc-engine`
   → `cc-fonts` → `cc-mode`, then `cc-cmds`/`cc-align`/`cc-styles`),
   which is what all of this is for.

The differential harness is worth rebuilding: a `PATTERN<TAB>TEXT`
file, an elisp file of `(string-match ...)` results, and a Scheme
runner that prints the same `TEXT PAT (START END (MATCH-DATA))` lines.
Normalize the trailing spaces and Emacs's trailing-nil trim before
diffing. `case-fold-search` nil in Emacs and `translate` `#f` here is
the baseline; the buffer's CANON table on both sides is the folded
run.

# `search.c` is on the engine, and the matcher's performance pass
# (2026-11-21)

Item 2 of the list above is **done**: `search.scm` compiles through
`re-compile-pattern`, matches through `re-search`/`re-match-2`, and
the old `%emacs-ere` translation, the 512-character copy window and
the simulated `\_<`/`\_>` assertions are unreferenced (delete them
when the tree is quiet). DEPARTURES.md's 2026-11-21 section has the
full account; the things the next session needs:

## Search-side facts

- **`buffer->re-text` takes STORE indices**, not buffer positions.
  `%buffer-re-text` converts BEGV/ZV/gpt by `(- ... (buffer-text-base
  txt))`. Passing positions made every buffer match one character
  early and dropped the last character - it looked like a matcher bug.
- **`match-data` emits `#f` for an interior unmatched register and
  elides only trailing ones**; `nil` when nothing has been searched,
  even with REUSE.
- The `re-search` registers are the engine's, shifted by BEGV:
  `%engine-regs-into-search-regs`. `%make-search-registers` follows
  `RE_NREGS` = 30 and never shrinks.
- Parse errors are `(error "Invalid regexp: ~s" message)`; the engine
  returns the C's `re_error_msgid` string.

## Matcher structure, and why

- **`make-match-attempt`** builds the helper closures, register
  vectors, failure stack and memo **once per search**; the returned
  procedure resets them per start position. A `re-match-2` call has
  its own attempt. Do not move the helpers back inside a per-attempt
  procedure: that was ~16 closures per start position, and measured
  at ~1 KB of the ~1.4 KB a search still allocates.
- **`done!` no longer raises.** It sets `result` and answers
  `%match-done`; `match-loop`/`end-of-pattern` thread the value back.
  The old `guard`/`raise` was ~40% of a failing search and allocated
  prompt and fluid state per attempt.
- **The failure stack is flat**: `entries` is `TAG VALUE TAG VALUE`,
  two slots per entry, the C's array of unions. It starts at
  `INIT_FAILURE_ALLOC` = 20, grows with `%fail-stack-ensure!`, and is
  reset rather than reallocated between attempts. `%push-failure-*!`
  and `%pop-failure-point!` inline the slot arithmetic; do not
  reintroduce a per-entry procedure call (that was 30% of the
  profile).
- `%execute-charset` and `re-fastmap-ref` use **`logbit?`** on the
  256-bit maps. `(logand map (ash 1 c))` allocates a bignum per
  character and was the single largest allocation source after the
  failure stack.
- **`(set! main-loop main-loop)` must stay.** Removing it segfaults
  in the compiled `regex-compile` on the first call **at O0, O1 and
  O2** - it is not the optimizer's inliner. Only `main-loop`'s
  assignment is needed; the other seven are cargo. Non-tail call,
  lambda indirection, a top-level caller and reordering `finish` were
  all tried and still crash, so the trigger is in main-loop's own
  compiled form.

## Performance numbers, and how to trust them

Compiled, `/tmp/bench/bench.scm`: symbol match 9.14 → **1.94 µs**;
failing bracket 267.8 → **35.0 µs**; `\(foo\|bar\)baz` over 200 chars
35.8 → **5.4 µs**; `\_<[a-z]+\_>` 11.0 → **2.7 µs**. Allocation per
search 232 KB → **1.4 KB**.

Against **Emacs 31.1 itself** (`string-match-p`, byte-compiled loop,
same texts, same session): 0.185 / 3.71 / 0.184 / 0.259 µs. The
**current** interleaved table (three rounds each side, load 1.8) is in
DEPARTURES.md's "final numbers" section: unfolded **11.5x / 8.1x /
21x / 10.6x**, folded (the editor's default) **7.2x / 15.5x / 8.4x /
8.3x**. The failing bracket improved from 35.0 to 30.1 µs through the
third and fourth waves; the 200-char skip from 5.4 to 3.9 µs. The
remaining ratios are one Scheme loop iteration per skipped character
and one `cond` comparison per dispatch arm - the structural floor.

`<re-text>` now carries the string or `#(STORE GPT GAP BASE)` as well
as the closure, and the fastmap loop and `%re-text-ref` read it
directly. Specializing the loop per substrate is what took the 200-char
skip from 8.6 to 5.4 µs.

**Measure with the machine quiet or not at all.** The later runs were
taken at load average 6-15 from the user's own processes, and the same
build varied by 10x between runs; one "regression" investigated during
the pass was entirely the load. Use allocation counts (`gc-stats`'s
`heap-total-allocated`) and `statprof` shares for A/B when the load is
not controlled.

Two micro-optimisations were tried and **reversed**: calling the
`<re-text>` ref closure through a local variable (slower - Guile
inlines the accessor-and-call form better), and a `case` dispatch
(Guile's `case` expands to `memv` over literal lists, worse than the
`=` chain). The remaining self-time is the dispatch loop, the
`%re-text-ref` closure per character, `%execute-charset`, and the
stack walk - see the DEPARTURES table before choosing one.

### The third wave: bitmap tables and the failure path (2026-11-21)

- **`<re-charset>` and `<re-fastmap>` both carry a 256-entry boolean
  vector** (`table`) beside the integer bitmap, and the hot tests read
  the vector: 11 ns against `logbit?`'s 20 ns compiled. The integers
  stay - the charset map for `mutually_exclusive_p`'s `logand`, the
  fastmap bits as `analyze_first`'s accumulator. A charset with no
  ranges and no class bits (`simple?`) answers a bitmap miss without
  calling `%execute-charset`.
- **`fail!` answers through the failure stack's `pop-str` field**, not
  `values`; the three-way opcode test is an `or` of `=`s rather than
  `memv` over a fresh list; and the one-line local wrappers around
  `%push-failure-point!`, `%memo-*` and `%check-infinite-loop` are
  gone. Do not reintroduce a `let-values` or a `(list ...)` in that
  path: each is one allocation per backtrack.
- A/B numbers and the CPU-time measurement caveat are in
  DEPARTURES.md's "third wave" section. In short: failing bracket
  35.0 → 32.5-33.1 µs at *higher* load, 200-char skip 5.35 → 4.05 µs
  (CPU-time A/B: −15-18% and −20-25%).

### The fourth wave: the ASCII translate cache (2026-11-21)

- **A compiled pattern caches its translate table for characters
  0..255** (`translate-vec` on `<re-pattern-buffer>`, built lazily by
  `re-translate-vector`), because `char-table-ref` is 64 ns against a
  vector's 11 ns and folded matching asks once per character. Folded
  rows improved 10-27%; unfolded rows unchanged. **No C counterpart** -
  named as a host-compensation in DEPARTURES.md; do not describe it as
  the C's design.
- **The regexp cache key is `(PATTERN TRANSLATE TABLE)`**, not
  `(PATTERN ICASE TABLE)`: Emacs keys on `cp->buf.translate`
  (`search.c:220`). Fixed in `search.scm`.
- **Reordering the opcode `cond` was measured and reverted** (15-25%
  slower on the failing bracket), and **hoisting the failure stack into
  attempt locals was rejected by microbenchmark** (record accessor
  11.5 ns vs `vector-ref` 9.2 ns). Both are in DEPARTURES.md so they
  are not retried blind.
- Changing `<re-pattern-buffer>`'s fields means **clear the whole
  `~/.cache/guile/ccache`** - a stale `search.go` failed with
  `allocate-struct: Wrong number of arguments to <re-pattern-buffer>`,
  and `--no-auto-compile` loads stale `.go` happily. The `/tmp/bench`
  cached `.go` files are in the same cache and need deleting too when
  a record changes.
- The remaining profile (failing bracket): match loop self 40.7%,
  pop 13.9%, `%re-text-ref` 10.3%, push 9.0%, `fail!` 6.8%. That is
  the per-instruction Scheme loop and the stack's vector accesses -
  the structural floor.



## Next

1. **Done in this pass**: the dead translation block in `search.scm`
   (`%emacs-ere`, `%translate-emacs-regexp`,
   `%current-group-map`/`%current-assertions`, the assertion helpers,
   `%bol-flags`) is deleted, along with its `(ice-9 regex)` /
   `make-regexp` imports **and** the syntax, chartab and buffer names
   only it used (`fetch-char`, `standard-syntax-table`,
   `with-syntax-table`, `char-syntax`, `syntax-class-to-char`,
   `%setup-syntax-table`, `%class-in`, `sword`, `ssymbol`,
   `char-table-ref-and-range`, `char-table-parent`,
   `standard-category-table`). `search.scm` is 2,198 lines now, from
   3,114.
2. Then cc-mode, as planned; the engine prerequisite is now met.
3. `%re-text-ref` inlining: `<re-text>` already carries the store,
   gap and base (second wave), so what remains is specializing the
   matcher's per-character read by substrate, which is the last ~10%
   of self-time and a large change.

# cc-mode has started: the language-constant core (2026-11-21)

The regexp engine is committed (`c8dc5b4`) and measured against the
real cc-mode patterns, and the first cc-mode library is in.

## The engine against cc-mode's own regexps

25 patterns dumped from a running Emacs 31.1 (`c-symbol-key`,
`c-identifier-key`, `c-nonlabel-token-key`, `c-decl-prefix-re`,
`c-lang-const` strings from `c-matchers-1/2/3`,
`c-basic-matchers-before/after`, `c-complex-decl-matchers`,
`c-simple-decl-matchers`, `c-cpp-matchers`), on
`GITE/emacs/src/minibuf.c` (2,760 lines), with the same syntax table on
both sides:

| shape | Emacs | engine | ratio |
|---|---|---|---|
| 69,000 anchored `looking-at` (25 patterns x 2,760 line starts) | 0.51-0.52 µs/call | 1.61-1.67 µs/call | **3.2x** |
| 108,039 forward matches (whole-file `re-search` loop) | 4.53 ms/scan | 30.4 ms/scan | **6.7x** |

**The answers are exact**: per-pattern counts and the first five match
spans agree on all 25 patterns. Two traps when rebuilding this:
`find-file-noselect` puts the C file in c-mode, which changes `\s`
classes (`(fundamental-mode)` after opening); and Emacs's
`string-match` uses the *current buffer's* syntax table, while a
buffer's `looking-at` uses its own. `\=` never matches in a string
search on either side (measured), so a buffer-point harness must not
expect it in string mode.

The harnesses are `/tmp/ccdump2.el` (dump patterns as hex),
`/tmp/bench/cc-bench.scm`, `/tmp/emacs-ccbench.el`,
`/tmp/emacs-ccscan.el`, plus the match differential
`/tmp/bench/cc-matches.scm` and `/tmp/emacs-ccstrings.el`. They should
move into `tools/` when they are next touched.

## What landed

`schemacs/progmodes/cc-defs.scm`: `c-add-language`, the seven core
language declarations, the constant registry, `c-lang-defconst`,
`c-lang-const`, `c-get-lang-constant`, `c-find-assignment-for-mode`,
`c-lang-defconst-eval-immediately`, `c-lang-major-mode-is`.
`test/progmodes/cc-defs-test.scm` (21) is in the suite runner; the
library is in `loadup.scm`'s list and `imports.scm` is regenerated.

**Read DEPARTURES.md's "cc-mode step 1" before touching it.** The one
design departure: a VAL is source data evaluated on demand in its
defining module; `c-lang-const` bakes the value when it resolves at
expansion time and emits a runtime call when it does not. The
behavioural test that a baked use keeps its old value after a
redefinition is what pins it.

## Next, in order

1. **`cc-langs`'s half of the variable system**: `c-lang-defvar`,
   `c-lang-setvar`, `c-make-init-lang-vars-fun` and
   `c-init-language-vars` (`cc-langs.el:153`, `:4616`, `:4707`), plus
   `c-make-keywords-re` (`cc-defs.el:2147`) and
   `c-mode-symbol`/`c-mode-var` (`cc-defs.el:2106`). Those are
   the bridge from constants to buffer-local variables and are needed
   before any language data can be ported.
2. `cc-vars.el`'s defcustoms, then `cc-langs.el`'s `c-lang-defconst`
   data. Differential every (constant, language) pair against a
   running Emacs, the way the charset data was verified.
3. First visible milestone: `c-mode` opening `.c`/`.h` with the right
   syntax table and font-lock faces, compared face-for-face with
   Emacs. Indentation (cc-engine/cc-align/cc-cmds, ~22k lines) is the
   second milestone.

**Prerequisites still missing**: `easy-menu-define` (8 uses in
`cc-mode.el`; the menu rule says the menus ship with the mode) and a
`def-edebug-spec` declaration stub. `rx` is not needed (0 uses), and
cl-lib only for a handful of helper functions.

## cc-mode step 2: the language-variable system (2026-11-21)

`schemacs/progmodes/cc-langs.scm` now has `c-lang-defvar`,
`c-lang-setvar`, `c-make-emacs-variables-local`,
`c-make-init-lang-vars-fun` and `c-init-language-vars`; `cc-defs.scm`
gained `c-mode-symbol`, `c-mode-var`, `c-concat-separated`,
`c-make-bare-char-alt` and `c-make-keywords-re`. `cc-langs-tests.scm`
(12) is in the runner; both libraries are in `loadup.scm` and
`imports.scm` is regenerated. All 85 suites pass.

The key facts before building on it (DEPARTURES.md has the detail):
language variables are **buffer-local slots keyed by the Emacs
symbol**, read through `c-mode-var`/`buffer-local-value`, not symbol
values; `c-init-language-vars` expands per mode with literal values
baked and non-literal values left as runtime `c-lang-var-value` calls;
and **`c-make-keywords-re`'s symbol/non-symbol split is only exact once
c-mode's syntax tables are ported** - the standard table calls `+`
symbol syntax where c-mode calls it punctuation. Revisit it when the
syntax-table data lands.

## Next

1. **`cc-vars.el`**'s defcustoms (the option variables cc-mode and
   cc-engine read), then **cc-langs' language data**: `c-mode-syntax-table`
   and `c-lang-defconst` tables, with a differential of every
   `(constant, language)` pair against a running Emacs. The syntax
   tables also close the `c-make-keywords-re` question.
2. `easy-menu-define` is still the one missing primitive for
   `cc-mode.el`'s menus (8 uses), and `def-edebug-spec` needs a
   declaration stub.
3. Milestone: `c-mode` opens `.c`/`.h` with the right syntax table and
   font-lock faces, compared face-for-face with Emacs.

## cc-mode step 3: the C syntax tables (2026-11-21)

`cc-langs.scm` has `c-populate-syntax-table` and the
`c-make-mode-syntax-table`/`c-mode-syntax-table` constants; `cc-defs.scm`
has `c-major-mode-is`; `syntax.scm` exports `char-syntax-in` (table
explicit, needed because cc-langs is evaluated with no buffer). The
c-mode syntax table matches Emacs 31.1 **character for character** over
0..255 (55 runs, pinned in `cc-langs-tests.scm`), and
`c-make-keywords-re` now reproduces Emacs's operator classification too
- the step-2 caveat is closed.

The one mechanism to know: `c-major-mode-is` reads
`*c-langs-are-parametric*`, which the VAL evaluation binds; macro
expansion inside `eval` sees it, which is how Emacs's
`c--macroexpand-all` switch is reproduced. Do not expand a VAL with
that parameter false.

Still not carried from that section: the XEmacs syntax-table arm, and
`c-make-no-parens-syntax-table`/`c-identifier-syntax-table` (they need
the `c-recognize-<>-arglists` constants and the `c-mode-syntax-table`
variable plumbing).

Next: `cc-vars.el`'s defcustoms, then the `c-lang-defconst` language
data (the `c-<>-*`/operators/keyword tables), then the first `c-mode`
milestone (syntax table + font-lock faces), with `easy-menu-define`
still the one missing primitive for its menus.

## cc-mode step 4: the first of cc-vars (2026-11-21)

`schemacs/progmodes/cc-vars.scm` has the variables the port has needed so
far (the indentation switches, the five font-lock extra-type lists,
`c-make-font-lock-extra-types-blurb`, `c-string-list-p`, the buffer-local
comment-prefix and macro-regexp accessors). `cc-vars-tests.scm` (23) is
in the runner; the library is in `loadup.scm` and `imports.scm` is
regenerated. All 86 suites pass.

The file is partial on purpose - the style system comes with
cc-styles/cc-engine - and the naming rules are in DEPARTURES.md:
`defcustom` -> starred parameter, plain `setq` variable -> plain define,
buffer-local variable -> accessor + `set!` setter.

Next: the language data proper. The keyword lists
(`cc-langs.el:2287-3578`, ~85 `c-lang-defconst`s) are the first
tranche; `c-keywords` collects every constant whose name ends in
`-kwds`, so the whole list must be in before it can be compared. Port
the helpers it needs first (`c--set-difference`, `c--intersection`,
`c--delete-duplicates`, `c--mapcan`, and `c-make-keywords-re` is
already there), then each constant with a differential against Emacs -
the same method as the syntax table.

## cc-mode step 5: the whole of the language data (2026-11-21)

`schemacs/progmodes/cc-langs.scm` now has **every language constant in
`cc-langs.el`** - 354 names across all seven languages - and the
differential against Emacs 31.1 is **2472 of 2478 answers identical,
the 6 others order-only**. Read DEPARTURES.md's "cc-mode step 5" before
touching any of it.

## What is where

- `schemacs/core/cl-seq.scm` (new) - `cl-set-difference`,
  `cl-intersection`, `cl-delete-duplicates`, `cl-member`: the four
  `cl-lib` functions the constants are built with, with cl-seq.el's
  own quirks (default test is `eql`/`eqv?`; the `memq`-except-numbers
  path; `cl-intersection` answers the reverse of list2's order).
- `schemacs/eval.scm` (new) - `funcall` (`eval.c:3185`); a
  function is a procedure here, not a symbol.
- `schemacs/fns.scm` - `mapcar`, `mapcan`, `elt`, `%length`,
  `%string`, `identity`, `delete`, and `nth`/`nthcdr` moved here from
  `subr.scm` (they are fns.c's). `mapcar`/`mapconcat`/`nconc` treat
  `#f` as nil.
- `schemacs/data.scm` - `aref`.
- `schemacs/progmodes/cc-defs.scm` - `c--mapcan`/`c--set-difference`/
  `c--intersection`/`c--delete-duplicates` (Emacs's macros, procedures
  here), `c-emacs-features` (Emacs 31.1's value as a constant),
  `c-with-syntax-table`, `c-int-to-char`, `c-characterp`, `%c-true` /
  `%c-false` (Emacs truth for this tree's two nils),
  `c-lang-constant-names`, `c-register-emacs-variable-reader!`
  (`c-mode-var`'s bridge to the starred defcustom parameters), and
  `c-lang-const-expansion`.
- `schemacs/progmodes/cc-vars.scm` - registers the six
  `*-font-lock-extra-types` readers, which is what
  `c-known-type-key`'s `(boundp ...)` test is here.
- `schemacs/progmodes/cc-langs.scm` - `c-filter-ops`, `c-kwds-lang-consts`,
  the hand-ported six, and the generated data block (its header comment
  explains the translation rules).

## How to re-run the differential

`tools/cc-langs-diff/` - build both dumps, `python3 compare.py`, exit 0
when only the known order case remains. **This is the gate for any
change to the language data**: a regexp-valued constant must stay byte
for byte, and a list-valued one set for set. The two Emacs traps are in
its README: a failing constant makes Emacs `makunbound` the symbol and
poison every later language (the dump reloads cc-langs after an error),
and list order is obarray order and not comparable.

`tools/cc-langs-gen/` regenerates the block from a `cc-langs.el`; it
reproduces the checked-in block byte-for-byte from a clean work
directory, so use it rather than editing the data by hand.

## Not carried, and what each waits on

- **`c-keywords-obarray`** - no obarray here. `c-keyword-sym` and
  `c-keyword-member` are cc-engine's and can be indexed from
  `c-keyword-member-alist` when it arrives.
- **`c-mode-menu`** - `easy-menu-define`, the one primitive cc-mode.el's
  eight menus still need.
- The `t` fallback for `c-mode-menu`'s menu entries and the defcustom
  `:set` calls (already named in earlier handoffs) stand.

## Next, in order

1. **`cc-fonts.el`** (3,591 lines): `c-make-syntactic-matchers`,
   `c-basic-matchers-before/after`, `c-complex-decl-matchers`, the
   declaration detection machinery. Everything it reads from cc-langs is
   now in and exact; `c-keyword-member` needs the obarray replacement
   (a hash table over `c-keyword-member-alist` is the natural form).
2. `cc-engine.el` (16,747 lines) - the parser, state cache, `c-parse-state`.
3. `cc-mode.el` - the mode definitions, `c-init-language-vars` in
   anger, `easy-menu-define`, `def-edebug-spec`.
4. The milestone: `c-mode` opening `.c`/`.h` with the syntax table, the
   faces compared to Emacs, then indentation (cc-align/cc-cmds/
   cc-styles).

## Verified

All **87 suites** pass (`cc-langs-tests` 37, `cl-seq-tests` 21,
`cc-defs-tests` 21, `cc-vars-tests` 23, `fns-tests` 41, `subr-tests`
104, `loadup-tests` 16, `tty-editor-tests` 354), and `tools/pty-check.py
scratch` passes as a startup smoke test. **The pty battery as a whole
was not run this pass.** The differential is the language data's real
gate and it is green (see above).

**A running editor keeps the code it started with** - restart before
looking at any of it.

# cc-mode step 6: the preprocessor machinery, and two scanner fixes
# (2026-11-21)

`schemacs/progmodes/cc-engine.scm` is new, with cc-engine.el's first
tranche in the file's own order: the internal state variables and
`c-calculate-state`, the `c-macro-cache` family and every
preprocessor-directive function from `c-query-and-set-macro-start` to
`c-forward-to-cpp-define-body`, `c-forward-comment-minus-1` /
`c-backward-single-comment`, the basic utilities (`c-delq-from-dotted-list`,
`c-shift-line-indentation`, `c-keyword-sym`/`c-keyword-member`, the
string-syntax constants, `c-parsing-error`/`c-echo-parsing-error`, the
c-type property pair), `c-point` and `c-is-escaped`. `cc-defs.scm`
gained `c-save-buffer-state` and the character-property helpers;
`cc-vars.scm` gained `*c-report-syntactic-errors*`.

## The two primitive bugs this port found - both in `syntax.scm`

Read them before touching `forward-comment` or `parse-partial-sexp`;
DEPARTURES.md has the C for each.

1. **`back_comment`'s dispatch must use the merged `code`**, not the
   character's own class. With `orig-code` the merged `*/` looked like
   punctuation, `(forward-comment -1)` over a C block comment answered
   nil and stopped at the comment's last character. `orig-code` survives
   only for the C's "was it a two-char Sendcomment" test.
2. **The "ignore comment starters of a different style" test is the
   C's `else if` after the two-char conversions, so it must not see a
   `com2start`.** Its style is computed from one half of the pair, so
   without the guard every `/* ... */` reported lossage backwards.
3. `parse-partial-sexp`'s element 7 is nil when `comstyle` is 0; a
   truthiness test there answers 0 (0 is true in Scheme), and
   `c-end-of-macro`'s block-comment branch then never fires.

## What to know before extending it

- **State variables are buffer-local slots behind accessors**
  (`c-macro-cache` / `set!c-macro-cache`) and `c-macro-start` is the
  parameter `*c-macro-start*`; `c-shift-line-indentation`'s
  self-rebind is a `parameterize`.
- **`%c-langvar` reads a language variable's slot** (keyed by the Emacs
  symbol) with #f when the buffer has not initialised the language.
- **`c-keywords-obarray` is a lazily built hash keyed on the language's
  `c-keyword-member-alist`**, and the language comes from the buffer's
  `major-mode` (or `*c-buffer-is-cc-mode*`). A test buffer must set one
  of them; Emacs's obarray is a language variable and needs neither.
- **`c-point`'s BOD/EOD/BOSWS/EOSWS arms signal**, naming the helper
  they wait for (`c-beginning-of-defun-1`, `c-end-of-defun-1`,
  `c-forward-syntactic-ws`/`c-backward-syntactic-ws`). The other eleven
  arms are complete and measured.
- `c-benign-error`'s `(ding)` half is not ported; the message is all.

## The measurement method (the trap is fontification)

Every expectation in `cc-engine-tests.scm` (88) is Emacs 31.1's own,
measured in `emacs -Q --batch` in a real `c-mode` buffer first. **A
table that does not reset `c-macro-cache` before each probe is not
deterministic**: `c-beginning-of-macro` at 82 answered `(nil 82)` in
one Emacs run and `(t 56)` in another, because the buffer's jit-lock
fontification probes the same cache. The differential harness
(`/tmp/cceng-reset.el` / `ours.scm`, the same 55 lines, and a warm-cache
72-line table) resets explicitly; both are byte-identical.

## Next, in the file's order

1. `c-forward-sws`/`c-backward-sws` (the syntactic-whitespace engine,
   ~1,600 lines with their caches) and `c-forward-syntactic-ws` /
   `c-backward-syntactic-ws`, then `c-syntactic-content`, the debug
   helpers, `c-forward-comments`.
2. `c-beginning-of-statement-1` (664 lines) and its automaton, then
   `c-parse-state` and the declaration machinery - the rest of
   cc-engine.
3. cc-fonts, whose matchers read `c-keyword-member` (now working) and
   the parser.
4. cc-mode itself: the mode definitions, `easy-menu-define`,
   `def-edebug-spec`, and the first milestone (`.c`/`.h` open in
   c-mode with the syntax table and faces compared to Emacs).

## Verified

`test/progmodes/cc-engine-test.scm` (88) is in `tools/run-suites.py`
and the tree compiles with no warnings in the touched libraries.
`imports.scm` is regenerated. The full suite battery is **88/88**
(`cc-engine-tests` 88) and `tools/pty-check.py` is **100/100** on the
settled tree.

## cc-engine: the comment and whitespace tools (2026-11-21)

The layer under the syntactic-whitespace engine is in: cc-engine's
`c-forward-single-comment`, `c-forward-comments` and
`c-backward-comments` (`cc-engine.el:1631'-`:1790', moved up beside the
functions they belong with), and cc-defs' `c-skip-ws-chars-forward`/
`-backward`. The latter are procedures here, and cc-defs now imports
`editfns.scm` for `point`/`goto-char` - its one reach that far up,
named in the source.

Verification: a differential probes all five at every position of a
fixture with a block comment, two line comments, a continuation and a
multi-line comment - 295 answered lines, identical to Emacs 31.1. The
measured answers are pinned in `cc-engine-tests.scm`'s `comment_tools`
group (the suite is 107 passes now).

**Next**: `c-forward-sws`/`c-backward-sws` proper
(`cc-engine.el:2127', `:2381') with their `c-is-sws`/`c-in-sws`
property scheme and the `c-put-is-sws`/`c-put-in-sws`/
`c-remove-is-sws`/`c-remove-in-sws`/`c-remove-is-and-in-sws` helpers,
then the invalidate hooks (`c-invalidate-sws-region-*`), which also
want `c-literal-limits`/`c-literal-type`/`c-go-list-forward` and the
`c-doc-line-join-re` default from cc-mode.el. `c-forward-sws` also
reads `c-noise-macro-name-re` (cc-vars' defvar, default
`regexp-unmatchable') and `c-looking-at-c++-attribute`.

## cc-mode: scan-lists wrappers and token boundaries (2026-11-21)

cc-defs now has the whole `scan-lists` wrapper block - `c-safe`,
`c-forward-sexp`/`c-backward-sexp`, `c-safe-scan-lists`,
`c-go-list-forward`/`-backward`, `c-up-list-*`, `c-down-list-*`, the
`c-go-...` movers - and cc-engine has `c-simple-skip-symbol-backward`
and `c-beginning-of-current-token` (moved up; `c-backward-sws` reads
it).

**Fixed a bug in `c-major-mode-is`**: a quoted single mode expanded to
`(memq m 'pike-mode)`, a runtime error, and the non-literal branch
emitted `eq` whatever the value. Emacs's macro is `eq` for a symbol,
`memq` for a list, and evaluates a non-literal MODE once
(`cc-defs.el:1162`). Every earlier caller was inside a
`c-lang-defconst` and took the parametric branch, which is why nothing
had found it. Four shapes are pinned in `cc-defs-tests.scm`
(45 passes); note the return values are Emacs's raw answers - the list
itself for a list, not `t`.

**`c-safe` re-raises a quit** (Emacs's `condition-case` does not catch
one; a bare `guard` would), and cc-defs imports `quit-condition?` from
`command.scm` for it - its second reach upward, named in the source.

Verification: a 423-line token/list differential and a 50-line
list/mode table, both identical to Emacs 31.1. `cc-engine-tests` is
115 passes.

**Right-sizing the verification (Chris's point).** The full 88-suite
battery is for changes to *shared* primitives - `syntax.scm`, `buffer`,
`editfns`, `keyboard`, `xdisp` - because those reach every front end.
A cc-mode-only change (the cc-* libraries, which nothing else imports)
gets `cc-defs-tests`, `cc-langs-tests`, `cc-vars-tests`,
`cc-engine-tests`, `cl-seq-tests` and `loadup-tests`, plus
`python3 tools/pty-check.py imports scratch` when `imports.scm`/
`loadup.scm` changed - a couple of minutes, not twenty.

**Next**: the syntactic-whitespace engine proper still needs
`c-looking-at-c++-attribute` (which reads `c-literal-limits`, hence
`c-full-pp-to-literal`), the `c-doc-line-join-re`/`-end-ch` and
`c-noise-macro-name-re` defaults (cc-mode.el's and cc-vars'), the
`c-is-sws`/`c-in-sws` property helpers, then `c-forward-sws` and
`c-backward-sws` themselves, and the `c-invalidate-sws-region-*`
hooks with `c-before-change`/`c-after-change`.

## cc-mode: sws properties, noise macros, doc variables (2026-11-21)

The last prerequisites of the syntactic-whitespace engine that do not
need `c-literal-limits`: the `c-is-sws`/`c-in-sws` property helpers
(`cc-engine.scm`, procedures; debug faces not carried, `facep` is not
ported), the three doc-comment variables from `cc-mode.el:136'-`:147`
(`c-doc-line-join-re`, `c-doc-bright-comment-start-re`,
`c-doc-line-join-end-ch`, defined in cc-engine as a named placement
departure), and cc-vars' noise macros (`c-noise-macro-name-re` /
`c-noise-macro-with-parens-name-re` as slot accessors,
`*c-noise-macro-names*` / `*c-noise-macro-with-parens-names*` as
`define-custom` parameters, `c-make-noise-macro-regexps`).

`cc-vars-tests` 28, `cc-engine-tests` 123. **Right-sized verification is
now the rule**: the six cc suites plus `pty-check imports scratch` for
a cc-only change; the full 88-suite battery only for a shared
primitive.

**Next**: `c-literal-limits` (`cc-engine.el:5719') with its
non-LIM arm - `c-full-pp-to-literal` (`:3124'), `c-semi-pp-to-literal'
(`:2978') and `c-parse-ps-state-below` (`:2864') - then
`c-looking-at-c++-attribute`, then `c-forward-sws`/`c-backward-sws`
(`:2127', `:2381') and the `c-invalidate-sws-region-*` hooks with
`c-before-change`/`c-after-change`.

## cc-mode: literal positions, and two scanner bugs (2026-11-21)

The `c-semi-pp-to-literal`/`c-full-pp-to-literal` machinery is in
(`cc-engine.el:2700'-`:3270'`), with the three literal caches as
buffer-local slots, `c-literal-limits`/`-start`/`-type`, `c-in-literal`
and `c-truncate-lit-pos-cache`. `c-truncate-lit-pos/state-cache` waits
on the paren-state cache.

**Two `syntax.scm` primitive bugs fixed** (both measured against Emacs
first, regression-tested in `syntax-tests.scm`'s
`schemacs_editor_ppss_resume`):
- `prev_from` starts at `from - 1` (`syntax.c:3205`); starting it at
  `from` made a scan resuming on the second char of `/*` record the
  comment's start one late.
- `forw_comment`'s pending-syntax entry must run the C's
  `forw_incomment` two-char tests (pending syntax = first half, char at
  FROM = second, nothing consumed on a hit). Re-entering the loop made
  a scan resuming on the `/` of `*/` stay in the comment for ever.

**The test-harness hazard, worth remembering**: a buffer's syntax table
*is* the standard table object until something installs one, so a test
that does `modify-syntax-entry` without a copy mutates the standard
table for every later test. `with-buffer` in `syntax-tests.scm` now
installs a fresh copy for every test; one cache test builds its own
buffers and had to do the same.

**Nil-safe accessors**: `%c-car`/`%c-cdr`/`%c-cadr`/`%c-cddr`/
`%c-caddr` (exported) are Emacs's car/cdr of nil, for the one-element
answers the literal functions give. Use them wherever a literal answer
may be nil.

Verification: a 504-line per-position differential (seven probes over
the whole fixture) identical to Emacs 31.1 with syntax-table text
properties stripped; `cc-engine-tests` 140, `syntax-tests` 70. The full
88-suite battery and the pty battery were run because `syntax.scm` is a
shared primitive.

**Next**: `c-looking-at-c++-attribute` (now unblocked), then
`c-forward-sws`/`c-backward-sws` (`:2127', `:2381') with
`c-forward-syntactic-ws`/`c-backward-syntactic-ws`, and the
`c-invalidate-sws-region-*` hooks (they need `c-literal-limits`, now
here).

## cc-mode: the syntactic-whitespace engine (2026-11-21)

`c-forward-sws`, `c-backward-sws` and everything under them are in
(`cc-engine.el:1800'-`:2694'`): the `c-is-sws`/`c-in-sws` ladder, the
change hooks (`c-invalidate-sws-region-before`/`-after`, with
`c-sws-lit-type`/`c-sws-lit-limits` as plain variables),
`c-enclosing-c++-attribute`, `c-looking-at-c++-attribute`,
`c-partial-ws-p`, and `c-forward-syntactic-ws`/`c-backward-syntactic-ws`
(in cc-engine - a placement departure: Emacs has them in cc-defs, whose
import graph is this tree's). `c-point`'s `'bosws`/`'eosws` arms work
now. DEPARTURES.md has the traps and the measured tables.

**The trap that cost the two hangs is worth keeping**: both a `when`
whose test fails and a `cond` with no matching clause answer the
*unspecified* value in Scheme, which is **true**, where Elisp answers
nil. Both sws loops had one in condition position, so the engine spun
forever on ordinary text - and the symptom was a silent hang, not an
error. Grep for `(when` and `cond` in any port where the value is a
loop condition.

**The whitespace sets** are `%c-sws-any`, `%c-sws-horiz`,
`%c-sws-back-horiz`, `%c-sws-bol`, each ending in a literal no-break
space (U+00A0) as Emacs's inline strings do; Guile's `\xa0` escape
takes no semicolon.

**Testing anything that branches on the major mode** requires
`(parameterize ((*c-buffer-is-cc-mode* 'c-mode)) ...)`, because Emacs's
`c-buffer-is-cc-mode` is a buffer-local set by the mode's init and no
mode exists here yet.

Verification at the right size: the six cc suites (cc-engine-tests 170,
25 new) and `pty-check imports scratch` 2/2, plus whole-fixture
differentials against Emacs 31.1 - the two moves at all 102 positions
of the fixture, `c-partial-ws-p` over 101 pairs, the attribute functions
at 24 positions, and the change hooks' recorded types/limits and ladder
state - all identical.

**Next**, in cc-engine.el's order: `c-syntactic-content` (`:530`),
`c-beginning-of-statement-1` (`:730') and its automaton,
`c-parse-state` (`:3885'), and the declaration machinery; then
`c-before-change`/`c-after-change` (`cc-mode.el`) wiring the change
hooks, `cc-fonts`, and `cc-mode` itself.

## cc-mode: `c-syntactic-content', and the interval narrowing bug
## (2026-11-21)

`c-syntactic-content` is in (`cc-engine.el:530`). Porting it found and
fixed a **shared** bug: `intervals.scm`'s `object-length` computed a
buffer's length as `ZV - BEGV` (the restriction) where Emacs's
`create_root_interval` uses `BUF_Z - BUF_BEG` (the text). A property
written while narrowed created a root interval covering only the
narrowed text; the next write past it made a negative-length interval
and the tree corrupted (`balance-an-interval` "expecting struct: #f").
`validate_interval_range`/`interval_of` also now check `BEGV..ZV` and
signal "Args out of range", as the C's hard validation does, and
`text-property-stickiness` compares against `BEGV` (the C's
`ignore_previous_character = pos <= BUF_BEGV`) - it read BEGV-1 and
signalled, which took down `mode-line-tests` until fixed.

**The symptom to recognise**: an interval tree with
`total-length: -8` / "expecting struct: #f" from `balance-an-interval`,
after any `put-text-property` performed inside a narrowing (font-lock,
`syntax-propertize` and cc-mode all narrow). Regression tests are in
`textprop-tests.scm` (46 passes now). Because this touched
`intervals.scm`/`textprop.scm`, the full battery was run.

Eight `c-syntactic-content` cases against Emacs 31.1 are identical and
pinned in `cc-engine-tests.scm` (178 passes).

**Next**: `c-beginning-of-statement-1` (`cc-engine.el:730'`, with its
automaton macros), then `c-parse-state` and the declaration machinery.

## cc-mode: token movement, statement barriers and virtual semicolons
## (2026-11-21)

The layer `c-beginning-of-statement-1` stands on is in: the token
movers, the statement-barrier walk, and the virtual-semicolon macros -
plus the two mechanisms that porting them needed (a `let` of a language
variable, and a registry standing in for the function obarray).

## What landed

- **Token movement** (`cc-engine.el:4947'-`:5191`), at the end of
  `cc-engine.scm`: `c-jump-syntax-balanced`/`-unbalanced`,
  `c-end-of-token`, `c-end-of-current-token`, `c-forward-over-token`,
  `c-forward-over-token-and-ws`, `c-forward-token-2`,
  `c-backward-token-2`, and the `-1` wrappers.
- **Statement barriers** (`:1457'-`:1560`): `c-punctuation-in` and
  `c-crosses-statement-barrier-p`, with `c-maybe-labelp` and
  `c-commas-bound-stmts` as parameters.
- **Virtual semicolons** (`:14184'-`:14243`): `c-at-vsemi-p`,
  `c-vsemi-status-unknown-p`, `c-c++-vsemi-p`, `c-at-macro-vsemi-p`,
  `c-macro-vsemi-status-unknown-p`.

## The two mechanisms, and why each was needed

**`*c-lang-var-overrides*`** (`cc-defs.scm`, exported; consulted by
`c-mode-var` and cc-engine's `%c-langvar`). A language variable here is
a buffer-local slot, not a symbol value, so `c-forward-token-1`'s
Emacs `(let ((c-nonsymbol-token-regexp "\\s.")) ...)` has nothing to
bind. The parameter is an alist of `(SYMBOL . VALUE)` that every reader
consults first - the dynamic binding spelled the only way this tree
can spell it. It is a parameter because Emacs `let`-binds it.

**`%c-lang-functions`** (`cc-engine.scm`) - a hash from the symbol a
language constant holds (`'c-at-macro-vsemi-p`) to the procedure, since
there is no function obarray. `c-register-lang-function!` fills it at
the end of the vsemi block; `c-at-vsemi-p`/`c-vsemi-status-unknown-p`
(cc-defs macros in Emacs) look the symbol up. The awk functions are not
ported (no awk mode here), so a language naming them answers #f where
Emacs would signal a void function - named in the file.

## The regexp-engine bug this found, and its fix

The first run of the barrier differential died inside a backward
syntactic-whitespace scan with

    Error in syntax_table logic for to-the-end intervals

`syntax.c`'s `RE_SETUP_SYNTAX_TABLE_FOR_OBJECT` (`:276'`, called from
`re_search_2'` at `regex-emacs.c:3509'` and `re_match_2'` at `:4103'`)
was not ported: the regexp engine read `SYNTAX(c)` through whatever
gl-state cache the last scan left. A backward scan can leave the
forward interval null, and the next `\s` search in that buffer then
raises. Both entry points now call `%setup-syntax-table` for a buffer
context (a string context uses its own table and needs none).

**This was shared**, so the full suite and pty batteries were run. The
regression is in `cc-engine-tests.scm`'s barrier group: it walks the
whole 98-pair `c-punctuation-in` table and then the differential's
seven barrier ranges, and was seen failing with the two setup calls
removed (`&message: "Error in syntax_table logic for to-the-end
intervals"`).

## Verification

Every expectation is Emacs 31.1's, and every table was a whole-input
differential, not a sample:

- token movement: all **102 positions** of the cc fixture, both
  directions, both the `-2` and the `-1` pairs - identical (`token-2`
  and `token-1` tables);
- `c-punctuation-in`: **98 pairs** - identical;
- `c-crosses-statement-barrier-p`: **7 ranges** of the cc fixture and
  **4** of a label fixture, recording `c-maybe-labelp` - identical;
- virtual semicolons: **all 36 positions** of a `Q_FOO (x)` fixture
  with `c-macro-with-semi-re` set - identical.

`cc-engine-tests.scm` is 220 passes (was 178); the six cc suites pass.
The harnesses are `/tmp/emacs-tok.el` + `/tmp/tok-diff.scm` and
`/tmp/emacs-csb2.el` + `/tmp/csb-diff.scm` (they should move into
`tools/` when next touched).

## Next

`c-at-statement-start-p` (`:1562'`), `c-on-identifier`,
`c-syntactic-skip-backward`, `c-looking-at-statement-block`,
`c-looking-at-special-brace-list`, `c-in-method-def-p` and
`c-looking-at-inexpr-block`, then `c-beginning-of-statement-1` and its
automaton; after that `c-parse-state` and the declaration machinery.
The vsemi path still wants `c-make-macro-with-semi-re`
(`cc-vars.el:1813`) and `c-macro-names-with-semicolon`, which the mode's
init calls - they come with `cc-mode.el`.

## cc-mode: the syntactic scans and the statement-start predicates
## (2026-11-22)

The layer `c-beginning-of-statement-1` stands on is in, in Emacs's file
order: `c-on-identifier` (`cc-engine.el:4852'`),
`c-syntactic-re-search-forward` (`:5196'`),
`c-syntactic-skip-backward` (`:5454'`), the `c-determine-limit` family
(`:5864'-`:6012'`), `c-looking-at-special-brace-list` (`:13584'`), and
`c-at-statement-start-p`/`c-at-expression-start-p` (`:1562'-`:1617'`,
where Emacs has them - they reach forward to the two scans above,
exactly as Emacs's file does).

## Verification

Whole-input differentials against Emacs 31.1, all identical:

- `c-syntactic-skip-backward` (limit nil and the delimiter set),
  `c-at-statement-start-p`, `c-at-expression-start-p`,
  `c-on-identifier` and `c-determine-limit` (N = 1, 5, 20, 200) at
  **every position** of the fixture;
- `c-syntactic-re-search-forward` at every position with `"[[{]"`,
  `"^;"` and `"\\_<int\\_>"`;
- `c-looking-at-special-brace-list` at every position of a pike
  fixture.

`cc-engine-tests.scm` is 261 passes; the six cc suites pass and the pty
battery's `imports` and `scratch` checks pass.

## Three host-language traps this found, and the tests that pin them

1. **`set!` is not `setq`.** In value position Guile's `set!` returns
   the *unspecified* value - and in one context a **zero-values**
   result: `(and (c-beginning-of-macro limit) ... (set! macro-start
   (point)))` gave "Zero values returned to single-valued
   continuation", and
   `(< check-pos (save-excursion ... (set! last-token-end-pos (point))))`
   gave "Wrong type argument in position 2: #<unspecified>". Both are
   `(begin (set! v x) v)` now. Any ported `setq` whose value is read
   needs this.

2. **Argument evaluation order is unspecified, and the compiler does
   not use the interpreter's order.** The C's

       (> (point) (progn (c-backward-syntactic-ws limit) (point)))

   reads point *before* the skip; written as the same expression in
   Scheme the compiled code evaluated the second operand first, so the
   comparison saw the *moved* point and the outer loop never ran. It is

       (let ((before (point)))
         (c-backward-syntactic-ws limit)
         (> before (point)))

   now. **Any comparison or constructor with a side-effecting operand
   in a C `progn` must sequence the operands explicitly**; the
   interpreter and the compiler disagree, so this class does not
   reproduce under `guile -s` alone.

3. **`=` on characters.** `(= (char-before) (cdr type))` in
   `c-looking-at-special-brace-list` signals (characters are not
   numbers); it is `char=?`. Emacs compares characters as integers.

## The harness: cc-mode's `category` properties

`c-mode` marks `<` with the `category` property `c-<-as-paren-syntax`,
and `get-text-property` resolves it to a `syntax-table` of `(4 . 62)` -
so `parse-partial-sexp` sees an opener the mode's *syntax table* does
not declare. That propertization is `cc-mode.el`'s, not the language
tables'; until it is ported, the Emacs side of a differential must strip
it:

    (setq-local syntax-propertize-function nil)
    (syntax-ppss-flush-cache (point-min))
    (let ((inhibit-modification-hooks t))
      (remove-text-properties (point-min) (point-max)
                              '(category nil syntax-table nil)))

**Removing `syntax-table` alone is not enough** - the property is
`category`; and without `inhibit-modification-hooks` the removal runs
`c-after-change`, which puts it straight back. Our test buffers install
the mode's syntax table only, so both sides then agree.

## Next

`c-looking-at-statement-block-1`/`-block` (`:13647'`, `:13736'`), which
need `c-looking-at-c++-lambda-expression`, `c-just-after-func-arglist-p`
and `c-back-over-member-initializer-braces` first; `c-in-method-def-p`
(`:12171'`) and `c-looking-at-inexpr-block` (`:13917'`); then
`c-beginning-of-statement-1` (`:793'`) and its automaton; then
`c-parse-state` and the declaration machinery, `cc-fonts`, and
`cc-mode.el`.

# cc-mode: `c-beginning-of-statement-1`, and the `cond` that answered
# true (2026-11-22)

`c-beginning-of-statement-1` (`cc-engine.el:793`) is in, with its
`c-bos-*` automaton, `c-in-method-def-p` (`:12171`) and
`c-looking-at-inexpr-block` (`:13917`), and the whole-input
differential against Emacs 31.1 is **2,292 of 2,292 identical** - every
position of a 23-statement fixture with six argument combinations
(lim, ignore-labels, noerror, comma-delim, hit-lim). DEPARTURES.md's
2026-11-22 section has the C for each rule and every departure; what
the next session needs:

## The two facts worth carrying into every remaining cc-engine port

1. **A `cond` with no matching clause must `(else #f)` wherever its
   value is tested.** Elisp's `cond` answers nil; Scheme's answers the
   unspecified value, which is true. The state machine's `(or (cond
   ...state...) (cond ...common...))` depends on the first answering
   nil to fall through - without the elsies it *hangs* (the automaton
   spins), and `c-looking-at-inexpr-block` returned truthy where Emacs
   returns nil, flipping the brace-block branch in
   `c-beginning-of-statement-1`. This is the `when`-in-value-position
   trap in its `cond` spelling, and it is now the first thing to grep
   for in a ported selector.

2. **Elisp's `if` takes any number of else forms, and the C uses it.**
   The semicolon `if` in `c-beginning-of-statement-1` has the whole
   rest of the function - automaton, hit-lim test, drain, substatement
   check, label handling - as its else list, so a bare-semicolon
   statement skips all of it. In Scheme that is an explicit `(begin
   ...)` in the else position; a port with a one-form else runs the
   limit test on the semicolon path (two answers of the hit-lim
   combination differed before this was fixed, and nothing else).

## The macro automaton

The `c-bos-*` macros are a `letrec-syntax` inside the function's `let`
(they close over `state`, `stack`, `saved-pos`, `pos`, `tok`, `ptok`,
`pptok`), and the two throwing ones take the `call-with-current-
continuation` escape procedure as their first argument - the C's
`(throw 'loop VALUE)` is `(done VALUE)`. `letrec-syntax`, not
`let-syntax`: `c-bos-pop-state` expands to a call to itself.
`c-bos-pop-state` must test `(pair? stack)`, not `stack`: the empty
list is true in Scheme and the C's `(if (setq stack ...) ...)` is a nil
test.

## What is left of cc-engine

`c-beginning-of-statement-1`'s dependencies are all in. Next in the
file's order: `c-looking-at-statement-block-1`/`-block` (`:13647`,
`:13736`), which need `c-looking-at-c++-lambda-expression`,
`c-just-after-func-arglist-p` and `c-back-over-member-initializer-braces`
(and thus `c-forward-<>-arglist` and `c-forward-type`), `c-in-method-
def-p`'s sibling `c-backward-cpp-define-body`, then `c-parse-state`
(`:3885`) and the declaration machinery, `cc-fonts`, `cc-mode.el`, and
indentation (cc-align/cc-cmds/cc-styles).

## Verification

The six cc suites pass (`cc-engine-tests` 325, 64 of them the new
`c-beginning-of-statement-1` group with every expectation Emacs 31.1's
own), and `pty-check.py imports scratch` is 2/2. `imports.scm` is
regenerated (112 libraries, 4,249 names).

# cc-mode: `c-parse-state' and the state cache (2026-11-22)

The state cache (`cc-engine.el:3260'-`:4850') is in `cc-engine.scm`:
`c-parse-state' and `c-parse-state-1', the two stale-entry removers,
`c-append-to-state-cache', `c-append-lower-brace-pair-to-state-cache',
`c-state-push-any-brace-pair', the strategy function, the narrowing
adjustment (`c-renarrow-state-cache'), the invalidation wrapper, the
brace/paren queries (`c-most-enclosing-brace', `c-least-enclosing-brace',
`c-safe-position', `c-whack-state-before'/`-after') and
`c-beginning-of-syntax'. DEPARTURES.md's 2026-11-22 section has the
representation notes and the three translation bugs.

## Verified

Two whole-input differentials against Emacs 31.1, both identical:

- the **forward scan**: `c-parse-state' at every one of the fixture's
  210 positions, recording the cache, `c-state-cache-good-pos' and
  `c-state-min-scan-pos';
- the **edit/invalidate/narrow table** (18 rows): an insertion at 100
  and the invalidation, a delete and the invalidation, six positions
  under a narrowing to [30, 180) after `c-state-cache-init', and three
  after widening.

The fixture and harnesses are `/tmp/state-fixture.c',
`/tmp/state-diff.scm' + `/tmp/emacs-state.el' (forward) and
`/tmp/state-diff2.scm' + `/tmp/emacs-state2.el' (the table). They
should move into `tools/' when next touched.

`cc-engine-tests.scm` is 348 passes: the new
`schemacs_editor_cc_engine_state' group pins five forward rows and all
18 table rows, each Emacs 31.1's own. `syntax-tests.scm` is 74, with
the `schemacs_editor_parse_sexp_ignore_comments' group for the reader
fix below. Full battery: **88/88 suites**, pty **100/100** (the latter
run alone).

## The bug that was one library down

The first difference the differential showed was braces *inside
comments* in the cache. `syntax.scm`'s `%parse-sexp-ignore-comments?'
answered the buffer-local with a literal `#f' default instead of the
global parameter, so every scan in a buffer that had not set the
variable saw comments as code - and cc-mode, which sets it
buffer-locally (`cc-mode.el:639'), never got there because there is no
cc-mode yet. The reader now falls back to
`(*parse-sexp-ignore-comments*)', which is what a buffer-local in Emacs
does. **Two defaults remain different from Emacs and are named in
DEPARTURES.md**: Emacs's globals start nil and are set by modes; this
tree's are `#t' and the `parse-sexp-lookup-properties' setters
(`font-lock.el:1531', `subr.el:2779') are not ported.

## Traps worth carrying into the declaration machinery

- **A C `while` whose condition is a `progn' must be a `when' whose
  test is the `begin' and whose body holds the assignments**, or the
  loop's iteration count is wrong with no error. The brace-pair scan
  and `c-append-to-state-cache' both had variants of this.
- **The value of the C's `(setq x ...)' in loop-control position is
  the new value.** Guile's `set!' answers the unspecified value, and a
  port that forces `#f' after it stops a loop the C continues. Write
  `(c-safe (begin (set! x ...) x))' where the C's value is the
  setq's.
- **`(and (goto-char p) (c-beginning-of-macro) TEST)' is not
  `(begin (goto-char p) (c-beginning-of-macro) TEST)'**: the `and'
  skips TEST when not in a macro; the `begin' evaluates it at `p',
  which is usually below the macro start and therefore true.
- The C's `c-state-maybe-marker' is a macro that *returns* the marker;
  here it is a procedure taking PLACE and MARKER and answering the
  marker, and the caller stores it.
- An empty cache is `'()'; the cons elements are proper-list members,
  so `(cons 7 #f)' is a bug that the `pair?' tests hide until a later
  copy.

## `c-looking-at-c++-lambda-capture-list'

The one piece of the lambda machinery that stands on nothing unported
(`cc-engine.el:14101`) is in, with a whole-fixture differential against
Emacs 31.1 at every `[' of a C++ fixture (21 rows, all identical -
lambda captures true; `[[attribute]]`, subscripts, and `[' inside a
string or comment false). `cc-engine-tests.scm` is 369 passes. The
`\[[...]` test pins the six-line function; `c-looking-at-c++-
lambda-expression' and `c-backward-over-lambda-expression' wait on the
declaration engine (`c-forward-<>-arglist', `c-forward-keyword-clause',
`c-forward-type').

## Next

The declaration machinery `c-beginning-of-statement-1''s remaining
callers need - `c-looking-at-statement-block-1'/`-block', which need
`c-looking-at-c++-lambda-expression', `c-just-after-func-arglist-p',
`c-back-over-member-initializer-braces', and through them
`c-forward-type' and `c-forward-<>-arglist'; then cc-fonts and
cc-mode.el. Those five functions are mutually recursive (name calls
type, type calls name and the arglist, the arglist calls type), so they
are one tranche with the tree's seam pattern (`*c-forward-type-
function*' and friends, installed as each definition loads).

# C variables Emacs makes customizable, and the leaf that unblocked them
# (2026-11-22)

Chris spotted `*words-include-escapes*` written as a plain parameter and
asked whether it should be `define-custom`, then asked for the rest of
the tree to be scanned for the same mistake. Both are done; the rule is
now in DEPARTURES.md and it applies to every C variable this tree
ports:

**`cus-start.el` is the bridge that makes a C `DEFVAR` a user option.**
Look the name up there; if it is listed, declare it with
`define-custom` carrying Emacs's `:type`, `:group`, `:version` and the
C docstring. Measured basis: `(custom-variable-p 'words-include-escapes)`
is non-nil in Emacs 31.1 though it is a `DEFVAR_BOOL` in `syntax.c`,
and `parse-sexp-lookup-properties` (not in cus-start) is nil.

## What landed

- **23 variables converted** to `define-custom`: the 20 the audit found
  (`*tab-width*`, `*indent-tabs-mode*`, `*truncate-partial-width-windows*`,
  `*window-combination-limit*`, `*window-combination-resize*`,
  `*default-frame-alist*`, `*resize-mini-windows*`,
  `*max-mini-window-height*`, `*frame-inhibit-implied-resize*`,
  `*read-buffer-function*`, `*read-buffer-completion-ignore-case*`,
  `*next-screen-context-lines*`, `*message-log-max*`,
  `*delete-by-moving-to-trash*`, `*text-quoting-style*`,
  `*file-coding-system-alist*`, `*completion-ignored-extensions*`,
  `*menu-bar-mode*`, `*use-dialog-box*`, `*use-short-answers*`) plus
  the three from `syntax.c` (`*words-include-escapes*`,
  `*parse-sexp-ignore-comments*`, `*open-paren-in-column-0-is-defun-start*`).
- **`schemacs/symbol-props.scm`** (new leaf): `fns.c`'s
  `Fget`/`Fput`, moved out of `intervals.scm`, which re-exports them.
  `custom.scm` imports the leaf, so `custom` now sits below
  `character` and `fns` - the two libraries whose variables were
  blocked from being `define-custom` (a library cannot import `custom`
  back).
- `imports.scm` regenerated (113 libraries, 4,319 names).

## How to re-run the audit

    emacs -Q --batch --eval '(with-temp-buffer (insert-file-contents
      "lisp/cus-start.el") (goto-char (point-min))
      (search-forward "(let* ((quoter") (goto-char (match-beginning 0))
      (let* ((f (read (current-buffer))) (b (assq (quote builtin-cus-vars) (cadr f))))
        (dolist (e (cadr (cadr b))) (princ (format "%s\n" (car e))))))'

then compare those 208 names with every `(define *x* (make-parameter`
in the tree (strip the stars). The same check applies to Lisp
`defcustom`s, which this pass did not audit: anything the tree ported
from a `.el` file's `defcustom` should be `define-custom` too.

## Verified

The full battery: **88/88 suites**, tree compiles with no warnings, and
`tools/pty-check.py` **99/100** with `completion-ui` red - the
documented between-key race (C-g straight after TAB); it passed 6 of 7
runs on its own on the same tree, and its failure screen was the known
"C-g left the minibuffer on the screen".

## Next for the declaration engine

`c-forward-keyword-prefixed-id`/`c-forward-id-comma-list` (Emacs's two
macros in this region, written as procedures here), then
`c-forward-<>-arglist` + recur, `c-forward-name`, `c-forward-type` -
one mutually recursive tranche with the seam pattern
(`*c-forward-type-function*` and friends).

# cc-mode: the declaration engine (2026-11-22)

The tranche the previous handoff named is in: the `c-found-types`
machinery, `c-forward-keyword-clause` with its two helpers,
`c-forward-<>-arglist` (+ recur and the backward twin), `c-forward-name`
and `c-forward-type`, plus the `<`/`>` category properties in
`cc-defs.scm`. DEPARTURES.md's 2026-11-22 section has the C and every
named departure; this is what the next session needs.

## Verification

The whole-input differential is the gate: both fixtures, every
position, six probes, `c-found-types` cleared - 2,280 + 1,620 answers
identical to Emacs 31.1. The harnesses are still in `/tmp/decl/`
(`emacs-dump.el`, `emacs-dump-c.el`, `ours-dump.scm`,
`ours-dump-c.scm`, the two fixtures); move them to `tools/` next time
they are touched. Two things they must do: parameterize
`*c-buffer-is-cc-mode*`, and strip the `category` property `cc-mode.el`
puts on `<`/`>` from the Emacs side.

`cc-engine-tests.scm` has the `schemacs_editor_cc_engine_declaration`
group (31 rows, every interesting answer of the differential); the suite
is 425 passes. `search-tests.scm` is 93 with the three regexp
reproducers.

## The trap that cost the most: a cached *script*

`cc-engine-tests` failed `(K 15)` with point 8, deterministically, while
the same probe in a fresh script passed and the whole-input differential
was 0. The cause was `~/.cache/guile/ccache/.../cc-engine-tests.scm.go`
- **Guile caches compiled *scripts* too**, and `--no-auto-compile` loads
one if it exists, exactly as for libraries. The cached copy predated the
fix being tested, so the suite ran an old expansion of
`c-init-language-vars`.

The tell: a suite failure that no fresh script reproduces and that no
differential sees. `rm -rf ~/.cache/guile/ccache` before trusting a
direct `guile -s` run, or (better) run the suite the way
`tools/run-suites.py` does - it points `XDG_CACHE_HOME` at a fresh
temporary directory, which is why the runner was green while the direct
run was red.

## The bug the declaration engine exposed

`c-keyword-sym` used to build its keyword table **lazily on first
lookup**, and that build evaluates `c-keyword-member-alist`, which runs
`c-make-keywords-re` -> `string-match` over every keyword. Called from
`c-forward-keyword-clause` - whose caller's `looking-at` match data it
is about to read - it replaced that match data with the last keyword
string checked (`co_yield`), and the clause moved point to the wrong
place. `c-keywords-obarray` is now a `c-lang-defvar` in `cc-langs.scm`,
built at `c-init-language-vars` time as Emacs does, and
`c-keyword-sym`/`c-keyword-member` are pure table reads. **The general
rule**: anything reachable from inside a `looking-at` context must not
evaluate language data, and Emacs's init-time placement is what
guarantees it.

## Regexp engine

Three real bugs found and fixed (DEPARTURES has the C):
`%check-infinite-loop` compared an index with the vector; the loop
opcode's `!analyze_first` negation was missing; the memoization now has
the C's two-phase threshold and `prememo`'s one-in-eight fastpath.
`search-tests.scm` pins `\\(a*\\|c\\)*` on "c" (Emacs: 0, end 0) and
`\\(a\\|c\\)*` (end 1).

## Next, in cc-engine.el's order

1. `c-forward-declarator` (`:10161'`), whose implicit-int branch
   `c-forward-type` currently signals an error for.
2. `c-looking-at-statement-block-1'`/`-block` (`:13647'`, `:13736'`),
   which need `c-looking-at-c++-lambda-expression',
   `c-just-after-func-arglist-p' and `c-back-over-member-initializer-braces'
   - and those call `c-forward-type' back, so the recursion the previous
   handoff expected now closes on real functions rather than seams.
3. Then `cc-fonts` (whose matchers can now use `c-keyword-member`),
   `cc-mode.el` (`easy-menu-define` is still the one missing primitive,
   plus a `def-edebug-spec` stub), and the first milestone: `.c`/`.h`
   open in c-mode with the syntax table and faces compared to Emacs.

Right-sized verification for cc-only changes: the six cc suites plus
`python3 tools/pty-check.py imports scratch`; the full battery is for
shared primitives (`regex-emacs.scm` was one, and the full battery was
run on this tree before the memo/obarray changes - the regex and cc
suites were re-run after them on a fresh cache).

# cc-mode: the declarator (2026-11-22)

The tranche after the declaration engine is in: the member-initializer
brace walk, the C++20 constraint machinery and `c-forward-declarator`
itself, with `c-forward-decl-arglist` under it and the recursion closed
on real functions. DEPARTURES.md's same-day section has the C for every
rule and the bugs in full; this is what the next session needs.

## What landed

`cc-engine.scm`, in Emacs's order at the end of the file:
`c-back-over-member-initializer-braces`, `c-forward-class-decl`,
`c-forward-primary-expression`, `c-forward-constraint-clause`,
`c-forward-c++-requires-clause`, `c-in-id-arglist`,
`c-forward-decl-arglist`, `c-forward-declarator`.

`c-forward-declarator` returns Emacs's six-element list
`(ID-START ID-END BRACKETS-AFTER-ID GOT-INIT DECORATED ARGLIST)`, and
its `c-last-identifier-range` is the tree's parameter
`*c-last-identifier-range*` (`c-forward-decl-arglist` `parameterize`s
it, as Emacs `let`-binds it).

## Before touching it: the four truthiness rules this tranche found

All four are the tree's recurring class, and each changed an *answer*:

1. a `cond` with no matching clause **must** have `(else #f)` wherever
   its value is tested - `c-on-identifier`'s operator branch answered
   the unspecified value (true) and made every rejected thing look like
   an identifier;
2. `c-backward-token-2` compared a char with `=` (a type error,
   reachable only with COUNT 0 on syntactic ws) - it is `char=?`;
3. `c-forward-syntactic-ws`/`c-backward-syntactic-ws` answer Emacs's
   macro answer now - nil from the `when` form, and a bare
   `c-forward-sws`/`c-backward-sws` with no LIMIT;
4. `c-forward-sws`/`c-backward-sws` answer nil on every path (explicit
   `#f`s now), because `c-forward-primary-expression` reads them in a
   loop condition.

And one balance trap worth re-reading: a block can be *balanced* and
still be the wrong shape. `c-forward-decl-arglist`'s `if` was
two-armed because its `and` closed a paren early, and the function
returned nil everywhere. Only the differential saw it - the reader and
the compiler did not.

## Verification

The whole-input differential: 11 probes at every position of three
fixtures (C++, the old C++ fixture and C), `c-found-types` cleared per
call - **14,498 answers identical to Emacs 31.1**. The harnesses are
`tools/cc-decl-diff/` (`README.md` has the three commands).

**The cache caveat, which matters for every future test here**: a
position's answer can depend on what was probed *before* it in the same
buffer, because cc-mode caches in text properties (`c-is-sws`,
`c-in-sws`, `<>`-as-paren). The differential was self-consistent (both
sides saw the same history); a test that probes in one long-lived
buffer is not Emacs's fresh answer. The new test group builds a fresh
buffer per row, and its 44 expectations are Emacs's one-probe-per-buffer
answers.

## Next, in cc-engine.el's order

1. `c-do-declarators` (`:10379`) - it only waits on
   `c-looking-at-statement-block`.
2. The statement-block walkers (`:13647`, `:13736`) and the lambda
   machinery (`:14113`, `:14169`), whose dependency
   `c-forward-<>-arglist`/`c-forward-keyword-clause`/`c-forward-type`
   is now in.
3. `c-forward-decl-or-cast-1` (`:10541`) - the largest remaining piece;
   then `c-just-after-func-arglist-p`, `c-at-toplevel-p` and the
   member-initializer walkers (`:9885`, `:9911`).
4. Then cc-fonts, cc-mode.el (`easy-menu-define` still the one missing
   primitive, plus a `def-edebug-spec` stub), and the first milestone:
   `.c`/`.h` open in c-mode with the syntax table and faces compared to
   Emacs.

Right-sized verification for cc-only changes: the six cc suites plus
`python3 tools/pty-check.py imports scratch`; regenerate
`imports.scm` with `tools/gen-imports.scm` after adding an export.

# cc-mode: the declaration decision and the statement block (2026-11-22)

The tranche the previous handoff named: `c-do-declarators`,
`c-forward-decl-or-cast-1` with its two `c-fdoc-` helpers,
`c-forward-objc-directive`, `c-at-toplevel-p`,
`c-just-after-func-arglist-p`, `c-looking-at-decl-block`,
`c-directly-in-class-called-p`, `c-search-uplist-for-classkey`, the
statement-block walkers, the C++ lambda machinery and
`c-back-over-member-initializers`. All of `cc-engine.scm`'s declaration
half is now in Emacs's file order; DEPARTURES.md's 2026-11-22 section
has the C for every rule and the four bugs in full.

## Verified

- **0 differences on all three fixtures** - the C fixture (6,480
  answers), the old C++ fixture (10,944) and `fixture-decl.cpp`
  (14,208), 25 probes at every position. `tools/cc-decl-diff/README.md`
  says how to re-run it, and its precondition rule (five functions are
  probed only at the `{`/`[` their docstrings require).
- The six cc suites pass; `cc-engine-tests` is 485 (the new
  `schemacs_editor_cc_engine_declaration_decision` group pins the
  Emacs-measured answers for the statement block, the declaration
  decision, the `<>` suppression and the parse-state cache).
  `python3 tools/pty-check.py imports scratch` passes.
- `imports.scm` regenerated: 113 libraries, 4,387 names.

## The four bugs, in one line each (all read out of the C)

1. **`c-parse-state`/`c-invalidate-state-cache` had no
   `c-with-<->-as-parens-suppressed`** - a comment saying "there are no
   category properties here" was true when it was written and false
   since the `<>` marking landed, so a marked `template <...>` stayed
   in the parse state as an open paren.
2. **`c-looking-at-statement-block` was balanced and wrong**: clause 2
   one `)` short, the next clause read as its body, and a stray `#t)`
   keeping the file balanced - so `((eqv? (char-after (point)) #\}))`
   was applied as a function: `Wrong type to apply: #f`. Fixed by
   rebuilding the function from the C's `pp` and splicing it whole.
3. **`c-remove-stale-state-cache-backwards` CASE 3** took its clause on
   `set!`'s unspecified (true) value and did `(+ 1 #f)`; the C's test is
   the `setq`'s value.
4. **`c-forward-decl-or-cast-1` CASE 19**: the `catch` body's last form
   is a `when`; Elisp's answers nil, Scheme's answers the unspecified
   value, so every undecided C++ construct became a declaration.

## Before touching it

- **A balanced file can be the wrong shape.** The tell is the *parsed*
  structure: print each `cond` clause's test and body count and compare
  with the C's `pp`; a paren counter cannot see a compensated
  misplacement.
- `c-forward-decl-or-cast-1` hoists the C's inner `let` into the outer
  one (the `c-fdoc-` closures must write its bindings); its
  `c-parse-and-markup-<>-arglists` `parameterize` closes right after
  the `catch`, where the C's `let` does.
- The differential's `A`/`O`/`U` probes share `c-parse-state`'s cache:
  an answer can depend on what was probed before it (both sides see
  the same history there; the unit tests build a fresh buffer per row).

## Next, in cc-engine.el's order

`c-forward-label`, the K&R/decl-header cluster
(`c-in-knr-argdecl`, `c-beginning-of-decl-1`, `c-end-of-decl-1`), the
bracelist machinery (`c-laomib-*`, `c-at-bracelist-p`), then
`cc-fonts`, `cc-mode.el` (`easy-menu-define` is still the one missing
primitive) and the first milestone: `.c`/`.h` opening in c-mode with
the syntax table and faces compared to Emacs.

# Handoff — cc-mode: the label scan, the K&R declarations and the
# declaration header (2026-11-22)

The tranche after the declaration decision: `c-forward-label`,
`c-in-knr-argdecl`, `c-skip-conditional`, `c-after-conditional`,
`c-after-special-operator-id`, `c-backward-to-block-anchor`,
`c-backward-to-decl-anchor`, `c-search-decl-header-end`,
`c-beginning-of-decl-1` and `c-end-of-decl-1`
(`cc-engine.el:11817'-`:12741'`). All of `cc-engine.scm`'s declaration
half is now in; DEPARTURES.md's 2026-11-22 section has the C for every
rule and both bugs in full.

## Verified

- **0 differences on all five fixtures** with 35 probes at every
  position: the C fixture (9,450 answers), the old C++ fixture
  (15,960), `fixture-decl.cpp` (20,720), the new `fixture-label.c`
  (5,530) and the new `fixture-knr.c` (7,560) - 59,220 in all.
  `tools/cc-decl-diff/README.md` has the five commands and the
  precondition rule (the two anchors join the `{`/`[`-guarded probes).
- The six cc suites pass; `cc-engine-tests` is 506 (the new
  `schemacs_editor_cc_engine_label_knr` group pins the Emacs-measured
  answers for every new function). `python3 tools/pty-check.py imports
  scratch` passes. `imports.scm` regenerated (4,397 names).

## The two bugs

1. **`c-cast-parens` holds Elisp characters as integers.** The tree's
   dump has `(40)`, `char-before` answers a character, so
   `(memv #\( '(40))` was false and every C cast was rejected -
   `c-forward-decl-or-cast-1` answered a declaration where Emacs
   answers `cast`, and `c-just-after-func-arglist-p` stopped moving.
   Fixed with `char->integer` at the one comparison. Any future
   language constant transcribed from Elisp character literals needs
   the same conversion.
2. **`(when (begin op1 ... op8) (loop))` where the C has
   `(while (and op1 ... op8) t)`.** The `begin`'s last operand
   (`(begin (c-forward-syntactic-ws) #t)`) is always true, so the
   drain operand's `#f` never stopped `c-in-knr-argdecl`'s loop and it
   walked past the body into the next declaration.

## Also landed: `c-make-macro-with-semi-re`

The Qt fixture exposed that the vsemi machinery had no mode-side
initialisation: `c-make-macro-with-semi-re` (`cc-vars.el:1813`, called
from each mode in `cc-mode.el`) was unported, so `c-macro-with-semi-re`
was nil and `c-at-vsemi-p` false on every `Q_OBJECT`-style line. It is
in `cc-vars.scm` now with `c-macro-names-with-semicolon`, its output
byte for byte Emacs's (including regexp-opt's shared-prefix form), and
the differential harnesses and the cc-engine test helpers call it after
`c-init-language-vars`, as a mode's init does. `cc-vars-tests` is 32.

## Before touching it

- **A `cond` with no matching clause must `(else #f)` wherever its
  value is tested**, and Elisp's `when` used as a value must be an
  `if` with an explicit `#f`. `c-forward-label` needs both in two
  nested places (the QT selector and its `when`).
- **The differential is the gate**: `tools/cc-decl-diff/README.md`.
  Its fixtures now include labels and K&R declarations; the harnesses
  (`emacs-decl*.el`, `ours-decl*.scm`) have 35 probes each. The
  printer treats a cons whose cdr is `#f` as a proper list, because
  that is Emacs's nil.
- **Compile after every edit before believing a diff** - a stale
  `cc-engine.scm.go` made the first `(else #f)` fix look like it did
  nothing (the documented trap, and it cost a round here).
- To find which operand of a failed `and` misbehaved, load an
  instrumented copy of the function from a scratch file (replace
  operands with `(begin ... (display ...) ...)`); the parens do not
  change and it runs in the same library environment.

## Next, in cc-engine.el's order

The bracelist machinery (`c-laomib-loop`, the cache functions,
`c-at-bracelist-p`), then `c-most-enclosing-decl-block`,
`c-cheap-inside-bracelist-p`, `c-backward-typed-enum-colon`,
`c-backward-over-enum-header` and `c-at-enum-brace`, the concept
walkers, then `cc-fonts`, `cc-mode.el` (`easy-menu-define` is still the
one missing primitive, plus a `def-edebug-spec` stub) and the first
milestone: `.c`/`.h` opening in c-mode with the syntax table and faces
compared to Emacs.

# Handoff — cc-mode: the bracelist machinery (2026-11-22)

The tranche the previous handoff named is in: `c-most-enclosing-decl-block`,
`c-cheap-inside-bracelist-p`, `c-backward-typed-enum-colon`,
`c-backward-over-enum-header`, `c-at-enum-brace`, `c-laomib-loop` with
its cache family, `c-looking-at-or-maybe-in-bracelist`,
`c-no-bracelist-cache`, `c-strip-conses` and `c-at-bracelist-p`
(`cc-engine.el:12966'-`:13582'`), plus `butlast` (`subr.el`, in
`subr.scm`). DEPARTURES.md's 2026-11-22 section has the C and the five
bugs in full.

## Verified

- **0 differences on all eight fixtures** with 35 probes at every
  position: the C fixture (11,880 answers), the old C++ fixture
  (20,064), `fixture-decl.cpp` (26,048), `fixture-label.c` (6,952),
  `fixture-knr.c` (9,504), `fixture-qt.cpp` (4,708), the new
  `fixture-brace.c` (10,472) and the new `fixture-brace.cpp` (11,044) -
  100,672 in all. `tools/cc-decl-diff/README.md` has the eight
  commands and the precondition rule.
- The six cc suites pass; `cc-engine-tests` is 534 (the new
  `schemacs_editor_cc_engine_bracelist` group has 28 assertions, every
  expectation Emacs 31.1's on a fresh buffer per probe - cc-mode
  caches in text properties). `python3 tools/pty-check.py imports
  scratch` passes. `imports.scm` regenerated.

## The five bugs, in one line each (read DEPARTURES for the C)

1. **`'|c-non-after-{}-ops-re|` is not the symbol.** Guile's default
   reader has no `|...|` symbol syntax; `|x|` names a symbol with bars
   in it. The lookup got `#f`, `(not (looking-at #f))` was always
   true, and `{1, 2}` read as a brace block - the `i 74` line of
   `fixture-brace.c`. Use `#{...}#`.
2. **`c-looking-at-or-maybe-in-bracelist` was one `)` short**, with a
   stray close keeping the file balanced: the `if`'s ELSE became a
   second `begin` form and the `(cons bufpos ...)` became a third
   conjunct of the `and`. Rewritten whole from the C, then
   structure-checked before splicing.
3. **`c-backward-typed-enum-colon`'s `goto-char` was inside its
   `save-excursion`** - Emacs's is outside. It answered `t` without
   moving, so every strongly-typed enum failed.
4. **`(when (eq at-type 'found) ... t)` in a value position** of
   `c-forward-decl-or-cast-1`'s `maybe-typeless` branch: the
   unspecified value is true, the branch ran for every type, and
   `enum class E` answered `class` as the declarator. **Pre-existing**
   - `HEAD` has it; the new C++ brace fixture is what exposed it.
5. **The test helper must reproduce the mode's init**: without
   `(c-clear-found-types)` the suite died in `hash-ref` at the first
   `Point p{` - a test harness gap, not a cc-mode bug.

## Before touching it

- **The parsed shape is the check.** Two of the five were balanced
  files with the wrong shape; a structural dump (cond clause counts,
  `and` operand counts) named both. The reader and the compiler passed
  on them.
- **A pre-existing difference must be shown pre-existing**: `HEAD` in
  a scratch worktree answered 175 too.
- **Compile after every edit before believing a diff**, and remember
  `--no-auto-compile` still loads a stale `.go` - clear
  `~/.cache/guile/ccache` when a record changes.
- The differential's long-lived buffer is self-consistent but not
  Emacs's fresh answer; unit tests build a fresh buffer per probe.

## Next, in cc-engine.el's order

The declaration-property and syntax machinery between the bracelist
tranche and `cc-fonts`: `c-at-vsemi-p`'s neighbours, the `c-parse-state`
consumers that remain, then `cc-fonts.el` (whose matchers can now use
`c-keyword-member` and the bracelist functions), `cc-mode.el`
(`easy-menu-define` is still the one missing primitive, plus a
`def-edebug-spec` stub) and the first milestone: `.c`/`.h` opening in
c-mode with the syntax table and faces compared to Emacs.

# Handoff - cc-mode: the find-decl machinery (2026-11-22)

`cc-engine.scm` now has `c-literal-faces`, `c-collect-line-comments`, the
find-decl cache, the brace-stack cache, `c-find-decl-prefix-search`,
`c-find-decl-spots` and the found-type helpers; `cc-defs.scm` has
`c-got-face-at`, and `search.scm` has `match-string-no-properties`. The
section in DEPARTURES.md of the same date has the C each rule came from and
every departure.

Things to know before extending it:

- **The cfd variables are parameters** (`*cfd-limit*` etc.) and
  `c-find-decl-spots` `parameterize`s them; the macro uses `setq`, whose star
  rule calls a parameter to set it. `(setq *cfd-re-match-end*
  (re-search-forward ...))` is the shape.
- **The `setq` macro evaluates its value once** now. It used to expand to
  `(begin (var value) value)`, which ran a search in VALUE twice and made
  `c-find-decl-spots` skip spots. `syntax-tests.scm` pins it.
- **`'()` is true in Scheme**: every Emacs nil test on a list in this code is
  a `pair?` test (`(while (and (pair? c) ...))`), and `c-got-face-at` answers
  `#f`, not `'()`.
- **`cc-find-decl-spots`'s fixture test** is `schemacs_editor_cc_engine_find_decl`
  in `cc-engine-tests.scm`; the expected spot list is Emacs 31.1's.
- The `/tmp/blockA-D` and `/tmp/cfd*.scm` files from the earlier attempt are
  stale; the tree's code is the corrected one.

Next: `cc-fonts.el` (whose matchers call `c-find-decl-spots`), then
`cc-mode.el` (`easy-menu-define` and a `def-edebug-spec` stub are still the
missing primitives), then the first milestone: `.c`/`.h` opening in c-mode
with the syntax table and faces compared to Emacs.

# Handoff - cc-mode: cc-fonts' first tranche (2026-11-22)

`schemacs/progmodes/cc-fonts.scm` is new: the face-name constants,
`c-annotation-face`, `c-font-lock-context`, the font-lock helpers
(`c-put-font-lock-face` and friends, `c-fontify-types-and-refs`,
`c-skip-comments-and-strings`), the four matcher constructors and
`c-fontify-recorded-types-and-refs`. `cc-defs` gained `c-face-name-p`;
cc-engine now exports `c-literal-start`, `c-determine-limit` and
`c-beginning-of-decl-1`. DEPARTURES.md's same-day section has the details.

The one thing to know before writing the keyword data: **a matcher here is
a procedure of LIMIT, and an anchored highlighter is
`(MATCHER-PROCEDURE PRE-THUNK POST-THUNK ...)`**, where Emacs's data holds
forms spliced into a generated lambda. Scheme has no lexical `eval`, so
the data must carry procedures. `c-make-font-lock-context-search-function`'s
stanza LIM is a thunk for the same reason.

`c-make-inverse-face` is deferred (needs `copy-face`/`invert-face`/
`face-inverse-video-p`); its caller is in `c-basic-matchers-before`.

`cc-fonts-tests.scm` (15) is in the runner; the full battery is green and
the pty startup checks pass. Next: the keyword data and the fontification
commands, then `cc-mode.el`.

# Handoff - cc-mode: cc-fonts' keyword data, the cpp and basic matchers
# (2026-11-22)

`cc-fonts.scm` now carries `c-cpp-matchers` and `c-basic-matchers-before`
with everything under them, and both are verified face-for-face against a
running Emacs on C and C++ fixtures. What landed, and what the next
session must know.

## What landed

- **`c-cpp-matchers`** (the whole `t` assignment, `cc-fonts.el:550`):
  the `#error`/`#warning` message matcher (previous pass),
  `c-maybe-font-lock-wrong-style-comments`, the `#include` string
  matcher, the `#define` function/variable matcher, the `#if`/`#elif`
  context search, the directive-name matcher, the `#ifdef` negation
  character, the Pike hashbang, and the hard-space matcher with
  `c-make-inverse-face`.
- **`c-basic-matchers-before`** (`:790'`): the unclosed-string warning,
  invalid single quotes, multi-line strings, keyword constants, the
  regular-keyword matcher, the fully-qualified-name matchers (Java's
  dotted form and the general `::` one), C++20 modules, the
  equals-nontype declaration matcher, the Objective-C pair, and the
  negation character.
- **The functions they call**: `c-font-lock-cpp-messages` (previous
  pass), `c-make-inverse-face`, `c-annotation-face` (the defvar as well
  as the defface), `c-font-lock-invalid-single-quotes`,
  `c-maybe-font-lock-wrong-style-comments`, `c-font-lock-ml-strings`,
  `c-forward-c++-module-name`, `c-forward-c++-module-partition-name`,
  `c-font-lock-c++-modules`.
- **The primitives under them**:
  - `faces.scm`: `make-empty-face`, `copy-face`, `invert-face`,
    `face-inverse-video-p`, `internal-copy-lisp-face` (`faces.el:212'`,
    `:232'`, `:605'`, `:1072'`).
  - `cc-defs.scm`: `c-search-forward-char-property`,
    `c-search-backward-char-property` (`cc-defs.el:1462'`, `:1505'`) and
    the three `c-search-*-char-property-with-value-on-char` helpers
    (`:1595'`-`:1695'`).
  - `cc-engine.scm`: `c-get-ml-closer`, `c-ml-string-opener-around-point`
    (`cc-engine.el:7559'`, `:7575'`), and `%c-langvar` is now exported.
  - `cc-vars.scm`: `c-block-comment-flag` (`cc-cmds.el:261'` - a named
    placement departure; cc-cmds is not ported).
  - `editfns.scm`: `char-after` takes its POSITION optionally, as the
    C's `(char-after &optional POSITION)` does (it was required - see
    DEPARTURES).
  - `font-lock.scm`: `font-lock-compile-keyword` grew Emacs's
    `(MATCHER)` arm - a keyword with no highlights - which the C data
    contains (`(c-font-lock-invalid-single-quotes)` etc.); without it a
    one-element keyword reached `(cadr keyword)` and raised.

## Verification

The same harness as `c-cpp-matchers`: put the list in
`font-lock-keywords` and run `font-lock-fontify-keywords-region` in a
real `c-mode`/`c++-mode` buffer on both sides, then compare the runs of
`face` by position. Emacs 31.1's answers:

- C (`#include`, `#define`, `#if`, `#error`, `#endif`) - 10 runs,
  identical;
- C (`int x = 0; if (x) return NULL; sizeof (int); x = !x;`) - 5 runs
  (keywords, the constant `NULL`, the negation `!`; `int` deliberately
  unfaced at this level), identical;
- C++ (`int x; N::x = 1; using T = int; module foo; import bar; export
  module baz;`) - 9 runs (the `::` reference, the module keywords and
  their names), identical.

They are pinned in `cc-fonts-tests.scm` (23 passes).

## The traps this pass paid for

1. **`c-mode-var` mode-prefixes its suffix, and a language variable is
   not mode-prefixed.** `(c-mode-var "cpp-messages-re")` works by
   coincidence in `c-mode` (`c-cpp-messages-re`) and asks for
   `c++-cpp-messages-re` in `c++-mode` - "Void variable". Runtime reads
   of a `c-lang-defvar` go through `%c-langvar` and its own symbol
   (`(%c-langvar 'c-cpp-messages-re)`); `c-mode-var` is only for names
   like `c++-font-lock-extra-types`. **The C-only test passed with the
   wrong accessor**: the C++ fixture is what caught it.
2. **A value-returned `when` is the unspecified value when it does not
   fire.** `c-forward-c++-module-name`'s body is a `when`: as Emacs's
   nil it says "no name", as Scheme's unspecified it is *true*, and
   `c-font-lock-c++-modules` pushed it as a module name and died on
   `(car #<unspecified>)`. The same fix applies to the two
   `c-search-*-char-property` functions. Use `when-e` wherever a
   `when`'s value is returned.
3. **The anchored-highlighter slots are procedures of LIMIT.** Emacs
   *splices* the three slots as forms into a lambda that binds `limit`;
   a thunk cannot see it ("Unbound variable: limit"). The data writes
   `(lambda (limit) ...)`, and `c-make-font-lock-search-form` calls each
   with `limit`.
4. **The flat `(REGEXP SUBEXP FACE ...)` keyword spelling needs
   `font-lock-compile-keyword`'s `(MATCHER . HIGHLIGHT)` arm.** It
   exists here, but `(MATCHER)` - no highlights - did not, and
   `(cadr keyword)` raised "expecting pair".
5. **A `c-lang-defconst` VAL is a datum evaluated later**, so its
   `,@`/`when` splices must be Scheme: `(if TEST (list X) '())`
   (a `when`'s unspecified value cannot be spliced), and the list it
   builds must contain the *procedures* the vec is made of, not symbols.

## What is not carried, and what each waits for

- **The multi-line-string propertization.** `c-font-lock-ml-strings` is
  ported, but the `'(15)` `syntax-table` properties on the delimiters
  come from `c-ml-string-propertize` and `c-before-change`/
  `c-after-change` (`cc-engine.el:7100'`-`:7550'`, `cc-mode.el`), which
  are not. Until they are, the function only acts on delimiters that
  already carry the properties, which nothing sets. Named in its
  docstring and in DEPARTURES.
- The `c-clear-char-property-with-value*` family (`cc-defs.el:1555'`,
  `:1697'`) - those same change hooks are its only callers.
- `c-font-lock-declarators` (`cc-fonts.el:1099'`, ~390 lines) and
  `c-font-lock-declarations` (`:1421'`, ~1,400 lines) - the next
  tranche, and what `c-simple-decl-matchers`, `c-complex-decl-matchers`
  and the enum/label fontifiers stand on.
- `c-make-inverse-face`'s XEmacs arm, as always.

## The source-vs-binary fact, which now matters

**GITE's `lisp/` is Emacs 32.0.50 (master); the installed `emacs` binary
is 31.1**, and its compiled Lisp is older than GITE's sources. Every
behavioural measurement in this project has been against 31.1. They
agree everywhere this pass measured, but they do not everywhere:
`c-font-lock-cpp-messages`'s `'(1)`-to-`(3)` syntax-table rewrite is in
GITE's source and **not** in the installed 31.1's `.elc`, so that one
expectation was measured by running GITE's own source in the 31.1
runtime, not by calling the installed function. When the two disagree,
**the port follows GITE's source** and the difference is recorded; do
not "fix" a port to match the installed binary without checking the
source first.

# Handoff - cc-mode: the declarator fontifier and the context function
# (2026-11-22)

Two more of the pieces `cc-fonts.el`'s declaration machinery stands on are
in, both verified against Emacs 31.1.

## What landed

- **`c-font-lock-declarators`** (`cc-fonts.el:1099'`): the typedef
  bookkeeping (`c-typedef' property, `c--set-difference` with `:test
  equal?`), the identifier-prefix-key walk, the operator""_tag branch,
  the template-class default. Two Emacs-measured fixtures:
  `"int foo, *bar;"` at point 5 with LIST t/TYPES nil gives the two
  variable face runs, and `"MyType x;"` at 8 with TYPES t gives the type
  face. `c-fontify-recorded-types-and-refs` now answers nil, as Emacs's
  `while` does.
- **`c-get-fontification-context`** (`cc-fonts.el:1206'`): the whole
  function. Verified by a **whole-position differential** - every one of
  the 165 positions of a six-line fixture (function arglists, an
  initializer, a struct, an enum, an if, a C++ member-initializer list),
  called in order on both sides, answers identically. Eight
  fresh-buffer rows are pinned in `cc-fonts-tests.scm` (35 passes): a
  function's argument paren is `(arglist . t)`, an enum brace list is
  `(not-decl)`, and the rest are `(nil)`.

## The lesson that unblocked it: use `cond-e` in value position

The function is a tower of `cond`s whose values feed `and`/`or`, and
Emacs's `cond` answers nil when no clause matches. My first translation
used plain Scheme `cond` and added `(else #f)` by hand to the two that
needed it - and the hand-added clauses were the source of a long paren
muddle (balanced file, wrong shape; the compiler's "bad use of 'else"
was the tell each time). **The fix was to use `(schemacs core syntax-macros)`'s
`cond-e`**, which is Emacs's `cond` including the nil answer, so the
translation mirrors Emacs's text clause for clause with no added forms.
The same applies to `when`/`unless` whose value is returned (`when-e`),
which this pass also needed in the module-name helpers.

Diagnostic worth keeping: when a `cond` is suspected, read the file
(once balanced) and print the cond's clause count and each clause's car
- Emacs's own source can be read with `read` in `emacs -Q --batch` and
dumped the same way. "One clause where there should be eighteen" names
the swallowed region at once, and beats counting parens.

## The other porting rule this found

**Elisp's `(cdr nil)` is nil; Scheme's `(cdr '())` is an error.** The
brace-list clause calls `(c-at-bracelist-p ... (cdr (c-parse-state)))`,
and `c-parse-state` answers `'()` for a fresh buffer - the error surfaced
only at one position of the differential ("expecting pair: ()"). The port
uses `%c-cdr`, whose whole purpose is Emacs's cdr-of-nil.

## State and next

`cc-fonts.scm` now has, in Emacs's file order: the face names and
`c-make-inverse-face`, the helpers and matcher constructors,
`c-font-lock-cpp-messages`, the invalid-single-quote and wrong-style
comment fontifiers, `c-font-lock-declarators`,
`c-get-fontification-context`, `c-cpp-matchers`,
`c-basic-matchers-before`, `c-font-lock-ml-strings`, and the C++20 module
fontifier. `c-font-lock-single-decl` (`:1409'`) and
`c-font-lock-declarations` (`:1421'`) are in as well - see the
2026-11-23 section below, which is what made them match Emacs face for
face. Still to come: the enum and label fontifiers,
`c-simple-decl-matchers`, `c-complex-decl-matchers`,
`c-basic-matchers-after` and `c-matchers-1'-`3' - and then `cc-mode.el`
and the first C-mode milestone.

The scratch file `scratch-c-get-fontification-context.scm` in the repo
root is superseded by the tree copy; delete it when convenient.

# Handoff - cc-mode: `c-font-lock-declarations' matches Emacs, and the
# `<'-`>' change functions under it (2026-11-23)

The C++ fixture's declarations were one face run short: `int` inside
`static_cast<int>` was fontified in Emacs and not here. The cause was
not in cc-fonts. `c-find-decl-spots' asks `c-bs-at-toplevel-p' about a
candidate spot before it fontifies it, and that walk only treats a `<`
as a template opener when the `<` *already* carries open-paren syntax;
the "false matches" filter then drops any spot preceded by an unmarked
`<`. Emacs has the mark before fontification starts because
`c-common-init' ends by running `c-before-font-lock-functions' over the
whole buffer ("Starting a mode is a sort of change"), and the one that
matters here is `c-restore-<>-properties'.

So the pass became the `<>` bracket-property machinery itself, in
`cc-engine.scm` in Emacs's order (`:7035'-`:7537'), plus the two
`cc-defs` helpers it stands on. DEPARTURES.md's 2026-11-23 section has
the C for every rule and the three traps; in one line each:

* **`c-clear-<-pair-props'** and its four siblings, `c-end-of-literal',
  `c-unmark-<>-around-region', `c-before-change-check-<>-operators',
  `c-after-change-check-<>-operators', `c-<>-get-restricted',
  `c-restore-<>-properties', and (with the ml-string helpers at the
  file's end) `c-ml-string-make-closer-re',
  `c-c++-make-ml-string-closer-re' and
  `c-ml-string-opener-at-or-around-point'.
* **`c-new-BEG`/`c-new-END`** are buffer-local slots with the tree's
  accessor/setter pair; `c-old-END-literality' is not carried (its only
  setter is unported).
* **`cc-defs.scm`** gained `c-put-string-fence' and
  `c-search-forward-non-nil-char-property' (procedures; Emacs's are
  macros).
* **A language function value is resolved by hand** -
  `%c-lang-function' plus a `c-register-lang-function!' at load, as
  `c-at-vsemi-p' does - because Emacs `funcall's through the obarray.
* **`c-search-forward-non-nil-char-property` must answer `#f`** where
  Emacs's `when' answers nil, or `c-unmark-<>-around-region''s
  `while' never ends. The `when`-in-value-position trap again.

## How the tests stand in for cc-mode.el

`cc-mode.el' is not ported, and its change hooks are the only callers
of these functions. The tests replay `c-common-init`'s block by hand -
set (c-new-BEG c-new-END) to the buffer, call
`c-restore-<>-properties' over it - before `c-font-lock-declarations`
or the change-function probes. When `cc-mode.el' lands it calls them
for real.

## Verified

* `cc-fonts-tests.scm'''s `declarations' group: the whole-buffer face
  runs of both fixtures - 25 runs for the C one and 15 for the C++ one,
  identical to Emacs 31.1, `(142 145 font-lock-type-face)' included.
* `cc-engine-tests.scm'''s `angle_props' group: init marks
  `static_cast<int>''s brackets `(4 . 62)'/`(5 . 60)';
  `c-clear-<>-pair-props' removes both; a deletion driven through the
  three change functions leaves the `<` marked, as Emacs leaves it;
  `c-unmark-<>-around-region' clears a pair a change splits and leaves
  (c-new-BEG c-new-END) alone; and `c-end-of-literal' answers a
  string's end. That unmark row is also the regression test for the
  car-of-nil crash: `(car (cddr STATE))' must be `%c-car`, since a
  state outside a literal is a one-element list and Emacs's `(car nil)'
  is nil where Scheme's raises (DEPARTURES has the detail).
* `cc-defs-tests.scm'''s `props' group: the new search's value, point
  and nil arm, and the string fence.
* All 90 suites pass (`cc-defs-tests` 59, `cc-engine-tests` 553,
  `cc-fonts-tests` 37); `imports.scm` regenerated (114 libraries, 4,526
  names); `python3 tools/pty-check.py imports scratch' is 2/2.

## Next

The rest of `cc-fonts.el`: the enum and label fontifiers
(`c-font-lock-enum-body', `c-font-lock-enum-tail', `c-font-lock-labels',
`c-font-lock-ids-with-dollar'), then `c-simple-decl-matchers',
`c-complex-decl-matchers`, `c-basic-matchers-after' and
`c-matchers-1'-`3'. After that `cc-mode.el' - the mode definitions,
`c-before-change'/'c-after-change' and `c-font-lock-init', with
`easy-menu-define' and a `def-edebug-spec' stub as the two missing
primitives - and then the first C-mode milestone: `.c'/`.h' opening in
c-mode with the syntax table, the faces compared to Emacs.

The multi-line-string change machinery
(`c-before-change-check-ml-strings' and the ~700 lines after it) and
the indentation-analysis section at cc-engine.el's end
(`c-guess-basic-syntax' and friends) are the two remaining large
tranches in cc-engine; the first needs cc-mode.el's hooks, the second
comes with cc-align/cc-cmds.

# Handoff - cc-mode: the matcher data, and a full fontification pass that
# matches Emacs (2026-11-23)

`cc-fonts.el`'s matcher chain is complete: the enum/declaration
fontifiers, `c-font-lock-labels`, `c-font-lock-c++-lambda-captures`, the
`c-simple-decl-matchers`/`c-complex-decl-matchers`/`c-basic-matchers-after`
data, `c-matchers-1`-`3`, and the C++-`using`/`new` and Objective-C
fontifiers the data names. A full `font-lock` run over
`(c-lang-const c-matchers-3 LANG)` now reproduces Emacs 31.1's face runs
**exactly** on all six fixtures measured. DEPARTURES.md's 2026-11-23
section has the C and the traps; the things the next session needs:

## What to run, and how

* `cc-fonts-tests.scm`'s new `end_to_end` group is the gate: six
  fixtures, full fontification (`font-lock-default-fontify-region` with
  `(c-lang-const c-matchers-3 ...)`), every run list Emacs-measured with
  `(font-lock-ensure)` in a real mode buffer. If a matcher or the data
  changes, this is what sees it.
* **A mode's init is replayed by hand** (cc-mode.el is still not
  ported): set `(c-new-BEG c-new-END)` to the buffer and call
  `c-restore-<>-properties`, then set the buffer-local
  `font-lock-keywords` and call `font-lock-default-fontify-region`.
* The probe scripts are `/tmp/ours-esp.scm` + `/tmp/em-esp.el` (four/six
  fixtures, diffed). Move them into `tools/` next time they are touched.

## Two shared primitives were wrong, both found here

* **`looking-back`'s GREEDY test** only asked "does some match end at
  PT"; Emacs asks "does REGEXP match the *whole* S..PT". On
  `"/* aaa */"` at 10 it extended the match to 1 and painted a comment
  as its own delimiter. Fixed in `search.scm`; six Emacs-measured rows
  in `search-tests.scm`.
* **font-lock's delimiters**: `font-lock-comment-start-skip`/`-end-skip`
  are parameters, while `c-lang-setvar` writes a *buffer-local slot* -
  so a language's `font-lock-comment-end-skip` never reached the
  syntactic pass and closing `*/` got no delimiter face. The readers now
  take the parameter first, then the buffer slot.

Both are the "a port can have Emacs's shape and still be wrong" class:
one was an implementation whose comment claimed the right rule; the
other was two representations of the same variable that never met.

## The data's shape

* **`(eval . FORM)` entries are written as the values they evaluate to**,
  with the Emacs form quoted beside them - our language data is
  evaluated at `c-init-language-vars` time.
* **`c-known-type-key` is a thunk** in the matcher's regexp slot:
  `c-make-font-lock-search-form` accepts a string or a procedure of no
  arguments, and the thunk reads `(%c-langvar 'c-known-type-key)` at
  match time - the same deferral Emacs's `eval` gives.
* **A language's nil list must be `(or (c-lang-const X) '())` before
  `append`**, or the result is an improper list and `cl-delete-duplicates`
  (rightly) refuses it.
* **An anchored highlighter's three code slots are procedures of LIMIT**
  (see the cc-fonts header); the `c-promote-possible-types` bindings in
  the data are `parameterize`s around `c-fontify-types-and-refs`.

## The pty battery

**99/100**, the failure `completion-ui` - the long-documented
C-g-straight-after-TAB race (measured 8/10 alone; 9/10 after the check
was given `WAIT(b"possible completions:")` before its C-g and RET). It
is not on either fixed primitive's path (`looking-back` is called only
from font-lock's comment-delimiter branch, fill and replace). The WAIT
is a real improvement and does not close the check: one run in ten
still shows the pre-C-g screen, and distinguishing a lost C-g from a
screen captured a frame early is an investigation of its own.

## Next

1. The rest of `cc-fonts.el`: `c-get-doc-comment-style`,
   `c-compose-keywords-list`, `c-override-default-keywords`,
   `c-fontify-new-found-type` and the `*-font-lock-keywords`
   definitions (`:2567'-`:3143'`), then the doc-comment machinery
   (`:3143'-`:3593'`).
2. `cc-mode.el`: the mode definitions, `c-before-change`/
   `c-after-change` and `c-font-lock-init` (with `easy-menu-define` and
   a `def-edebug-spec` stub as the two missing primitives), which is
   what turns the tests' hand-replay into the real thing - and then the
   first C-mode milestone: `.c`/`.h` opening in c-mode through
   `auto-mode-alist`.

# cc-fonts is whole: the keyword variables, the doc comments, and java's
# modifier gap (2026-11-23)

`cc-fonts.el` is now ported through `:3593'` - the doc-comment machinery,
`c-compose-keywords-list`, `c-override-default-keywords`,
`c-fontify-new-found-type`, and all six `*-font-lock-keywords` variable
sets. **All four doc styles fontify face-for-face with Emacs 31.1**:
gtkdoc (C), javadoc (Java), autodoc (Pike) and doxygen (C++), measured
with `(font-lock-ensure)' on the same text in a real mode buffer.
DEPARTURES.md's 2026-11-23 section has the C and every stand-in; the
things the next session needs:

## Before touching it

* **The keyword variables are two things.** The Scheme variable keeps
  the name; the *function* half is the procedure registered in
  `*font-lock-keyword-variables*`, because `font-lock-eval-keywords`
  prefers a function (`fboundp` before `boundp`) and that is how the
  doc keywords get composed at font-lock setup. `font-lock-eval-
  keywords`' symbol branch had to grow the C's recursion (`while`) for
  that: a procedure entry was answered *as* the value, and
  `font-lock-compile-keywords` was handed a procedure.
* **The doc styles' names are looked up in two alists**
  (`%c-doc-font-lock-keywords`, `%c-doc-comment-properties`), filled at
  the end of the file. They stand in for Emacs's `intern-soft`/`boundp`/
  `symbol-value`.
* **The three doc variables are buffer-local slots behind accessors**
  in cc-engine now (`(c-doc-line-join-re)` etc.) - without that, one
  buffer's doc style leaked into every buffer, the font-lock comment-skip
  bug's shape. The two `c-set-doc-comment-*` macros are procedures (the
  name they compute is only data).
* **The C++ fontifiers are above the C keyword defs** (a placement
  departure): our matcher data holds procedures where Emacs's holds
  symbols, so `(c-lang-const c-matchers-3 c)` cannot be evaluated until
  `c-font-lock-c++-using` exists - and `c-using-key` is a never-matching
  regexp for C too, so the C list does reference it.
* **`font-lock-compile-keyword`'s `(MATCHER)` arm** (a one-element list)
  was `(not (pair? (cadr keyword)))`, and `(cadr '(x))` is an error; it
  is `(list-ref-safe keyword 1)` - Emacs's `(nlistp (nth 1 keyword))`.
* The pike doc style's line markup needs `c-current-comment-prefix`
  (`//+!?\\|\\**` in pike-mode, measured); `c-setup-paragraph-variables`
  sets it at mode init, so a test must set it by hand until cc-mode.el
  lands.

## The java declaration gap (open, pre-existing)

`public`/`static`/`abstract` before a java declaration leaves its
function name unfontified here where Emacs gives it
`font-lock-function-name-face`; `final` and no modifier both work. The
**one diverging call is font-lock's pipeline call to
`c-forward-decl-or-cast-1` with match-pos 0, context 'top, from point
1**: Emacs answers `(13 nil nil 8 t)`, ours nil - while the *same* call
outside the pipeline answers nil in both editors, so some pipeline-only
state (the syntactic pass and earlier matchers' text properties,
`c-find-decl-spots`' narrowing, or a cache) is the discriminator. Every
step outwards from that call (`c-forward-type`, `c-forward-decl-arglist`,
`c-go-list-forward`, a direct `c-font-lock-declarators` at the
declarator) matches Emacs. DEPARTURES.md has it. The javadoc test uses a
comment-only fixture so it pins the doc machinery, not this.

## Verified

All **90 suites** pass (`cc-fonts-tests` 43 -> 59, `window-tests`
18 -> 22) and `tools/pty-check.py` is **99/100** - `completion-ui` red
in the batch and **3/3 alone**, the documented race, on no path this
pass touched.

## The style variables are in cc-vars (2026-11-23, second pass)

`defcustom-c-stylevar`'s work is landed: `c-style-variables`,
`c-fallback-style`, `c-set-stylevar-fallback`/`c-stylevar-fallback`,
the sixteen style variables and the six paragraph/string variables
Emacs reads beside them - every docstring, type and value emitted from
a running Emacs 31.1, with `c-offsets-alist`'s whole syntactic-symbol
table as its fallback. Each style variable is **two names**: the
`*c-name*` parameter (the global, `default-value`) and
`(c-name)`/`(set!c-name v)` over a buffer-local slot (`symbol-value`/
`set`) - because Emacs's `c-style-variables-are-local-p` makes the
style per-buffer and a parameter alone would leak it. `c-offsets-alist`
is nil, not `set-from-style` (Emacs's own defcustom). Two stand-ins:
`c-valid-offset`'s functionp arm consults `%c-offset-function-names`
(a registry seeded with the 27 line-up names the shipped styles use;
cc-align extends it), and `c-default-value-sentence-end` is written at
its one use site as `(parameterize ((*sentence-end* #f))
(sentence-end))`.

**The six paragraph/fill variables are buffer-local now** (2026-11-23,
third pass): `paragraph-start`, `paragraph-separate`,
`paragraph-ignore-fill-prefix`, `adaptive-fill-mode`,
`adaptive-fill-regexp` and `adaptive-fill-first-line-regexp` are
parameter (global/default) + buffer-local slot behind
`(paragraph-start)`/`(set!paragraph-start v)`, all 45 readers
converted, and the four Elisp `let` sites are `buffer.sld`'s
`call-with-buffer-local` (save, set, run, restore - **killing the slot
when there was none**). So `cc-styles.scm`'s
`c-setup-paragraph-variables` can set them per buffer as Emacs does.
The hazard that cost an hour here: the mechanical call-site rewrite
also rewrote the accessors' own fallback, making them self-recursive -
every fill hung. Keep definition and call-site rewrites apart.
DEPARTURES.md's third-pass section has it in full.

## Next

cc-mode.el: the mode definitions, `c-before-change`/`c-after-change`,
`c-font-lock-init` (which installs
`*c-font-lock-fontify-region-function*` and the `font-lock-defaults`
list), the `easy-menu-define` primitive and a `def-edebug-spec` stub -
then the first milestone: `.c`/`.h` opening in c-mode through
`auto-mode-alist`, faces compared to Emacs. And the java gap above,
which the mode work will make much easier to reproduce.

# The quit path, and the scratch script that ate cc-engine.scm (2026-11-23)

Two unrelated things in one session: the pty battery's two failing checks
(`quoted-insert`, `tty-menu`), and the repair of `cc-engine.scm`, which an
imported scratch script had overwritten with a stale, unbalanced copy.

## `cc-engine.scm` was clobbered by `/tmp/bisect.py`

The file was found at 10,500 lines with an `unexpected end of input` at
its last form, missing the whole label/K&R and bracelist tranches that
HEAD has. The cause is not any edit: **`/tmp/bisect.py`**, a scratch
bisect harness from the find-decl work, has its loop at *module top
level* and begins each iteration with

    f='schemacs/progmodes/cc-engine.scm'
    src0=open('/tmp/cc-engine-current.scm').read()
    open(f,'w').write(src0)

so merely importing it rewrites the repo file with a stale copy. It was
imported by accident: `python3 /tmp/probe-menu.py` put the script's own
directory (`/tmp`) first on `sys.path`, and Python's `tempfile` imports
`random`, which imports `bisect` - `/tmp/bisect.py` shadowed the stdlib
module and ran its loop. The tell in the output was a `SyntaxWarning`
from a file nobody had run, followed by `c3 ERR c4 ERR ...` lines.

Recovered from `/tmp/base/schemacs/progmodes/cc-engine.scm` (13,729 lines,
the copy of the tree taken at 08:00 for the buffer-local baseline test -
`cp -a`, so its mtime is the source's and it predates the clobber),
reader-checked and compiled. The scratch script is now
`/tmp/bisect.py.disabled-moves-repo-file`.

**Method notes**: run Python with `-I` (or from a directory with no
scratch modules) - `-I` also implies `-P`, which keeps the script's
directory off `sys.path`; and a scratch harness that writes into the
repo must not do it at import time. A `cmp` against a known-good copy is
what identified the damage; `git diff` alone read like a huge deletion.

## The two battery failures: a real departure plus a stale `.go`

`quoted-insert` failed with the screen showing `Quit` in about four runs
of five, and `tty-menu` the same for its C-g case. There were two causes,
and both had to be fixed:

1. **A real departure in the quit path** (DEPARTURES.md, 2026-11-23).
   `read-key-event` is `read_char`, and it called `maybe-quit` at the top
   of every read and cleared `Vquit_flag` itself. Emacs answers a pending
   C-g as `quit_char` (`keyboard.c:2817`, `:4117`), clears the flag only
   under `inhibit-quit` (`:2824`), raises it in `read_key_sequence_vs`
   (`:12457`) and clears it after each key in `read_key_sequence`
   (`:11892`). The port now splits them the same way, and
   `read-quoted-char` is Emacs's `while` clause for clause, including
   `inhibit-quit` = `first` and the `(if inhibit-quit (setq quit-flag
   nil))` line - that binding is what makes a C-g whose SIGINT arrived
   before the read still be the quoted character. The hex-letter digit
   branch was also wrong (`code - ?0` instead of `10 + downcase - ?a`).
2. **`schemacs/imports.scm` was newer than its `.go`.** With
   `--no-auto-compile`, Guile still prints "source file ... newer than
   compiled" and loads the *source*: every editor then interpreted the
   generated user-environment library during startup. Measured before
   compiling: ncurses init output at 0.23 s, **first full screen at
   0.563 s**; the harness's "output then quiet 0.2 s" ended at ~0.45 s
   and the C-g arrived before the command loop's first read, so the new
   `maybe-quit` raised it. Compiled: first screen at ~0.48 s, and
   `quoted-insert` and `tty-menu` pass 5/5 each. **Compile the tree
   after `tools/gen-imports.scm` regenerates `imports.scm`** - it is a
   library like any other and the one with the most code behind it.

3. **A signal could not end a `select` wait.** Emacs's SIGINT handler
   longjmps out of `pselect` (`quit_throw_to_read_char`); a Scheme
   `sigaction` handler is deferred to a safe point. Measured on this
   Guile: a SIGINT during a blocking `select` makes `select` return an
   empty ready set **with the handler not yet run**, so the terminal's
   wait re-blocked with the flag set and nothing to see it - a C-g
   occasionally lost until the next key (`query-replace-quit` 9/10, the
   tight `completion-ui` C-g 9/10). `(schemacs keyboard)` gained
   `*signal-wake-function*`, called by `handle-interrupt` after setting
   the flag; the terminal installs a thunk that writes one byte to the
   pipe its wait already selects on (the back-door wake). 15/15 each
   afterwards. DEPARTURES.md has the full account.

Tests: `tty-editor-tests.scm`'s `schemacs_tty_editor_quit_read` group -
the inhibited read answering `quit_char` and clearing the flag, the
uninhibited read answering it and leaving the flag, the command loop
raising the pending quit and then reading the key, `quoted-insert`
inserting a pending C-g, and `handle-interrupt` setting the flag before
it wakes the wait. `tty-editor-tests` is 359 passes.

## The harness was reading ncurses' start-up as "the editor is ready"

The pty battery's remaining failures (`quoted-insert` with "Quit",
`scroll` with "the last line was not scrolled into view") were not the
editor: `drive()` called the editor ready on "any output, then 0.2 s of
quiet", and ncurses writes its initialisation (the alternate screen,
the clear) at ~0.25 s while the first full screen is at ~0.48 s. Keys
sent in that gap are read by the command loop's *first* iteration, not
by the command the check is driving - and a C-g sent there has no read
to be a key to, so its SIGINT records a quit that the loop answers as
"Quit". It came and went with the load, which is why the same tree gave
99/100, 98/100 and 100/100.

`drive()`'s readiness test is now **a mode line on the screen**, which
every screen the editor draws has (`MODE_LINE_RE`), then the quiet wait.
Measured after: `quoted-insert` 10/10 (was 1/5 at an earlier pass),
`scroll` 5/5. `pty-check.py`: **100/100**, and all suites pass (exit 0).

**When a check's failure screen looks like the editor never saw the key,
suspect this rule before the editor** - and remember the rest of the
rule: `settle()` is pacing, `WAIT`/`sleep`/`EXITED` are conditions. Two
checks were given real waits in this pass: `completion-ui`'s C-g now
sleeps 0.3 s after the completions row appears (the redisplay that draws
it finishes after the text matched; 0.1 s lost 1 run in 10 under load),
and `query-replace-quit` waits for each prompt before typing its answer.

## Where the cc-mode work stands unchanged

`cc-engine.scm` is restored to the state the bracelist and declaration
passes left it in (13,729 lines, compiled clean). The next tranche is
still `cc-styles.scm` (`c-style-alist`, `c-set-style-1`,
`c-get-style-variables`, `c-set-style`, `c-add-style`, `c-set-offset`,
`c-setup-paragraph-variables`, ...), then `cc-mode.el` and the
`.c`/`.h` milestone. The java modifier-keyword declaration gap is still
open and still reproducible.

## cc-styles is ported, and the four bugs under it (2026-11-23)

`schemacs/progmodes/cc-styles.scm` is `cc-styles.el` whole, verified
assertion for assertion against Emacs 31.1 (`cc-styles-tests.scm`, 60).
DEPARTURES.md's same-day "cc-styles: the style system" section has the
C and the details; the things the next session needs:

* **The data is an alist of proper lists**: `("gnu" (c-basic-offset . 2)
  ...)`, so `(cdr (assoc "gnu" c-style-alist))` is the variable alist.
  The first transcription wrapped the whole datum in one extra list and
  nothing matched; `(map car c-style-alist)` against Emacs's twelve
  names is what caught it.
* **`set!` on an imported binding is not "set the variable".** Guile
  raised `Wrong type to apply: ((c . c-lineup-C-comments))` (the new
  value applied as a procedure) from `c-set-offset`'s Emacs `(setq
  c-offsets-alist ...)`; the setter call `(set!c-offsets-alist ...)` is
  the correct spelling, and the buffer-local it writes is what Emacs's
  `setq` means. Any future port of a `setq` of a style variable must
  use its `set!` accessor.
* **`c-special-indent-hook` is a plain `defcustom`** - nil default, no
  `c-stylevar-fallback` property, no `c-fallback-style` entry - while
  still a member of `c-style-variables`. It is why the value after the
  gnu style is `(t c-gnu-impose-minimum)`: `add-hook`'s LOCAL arm seats
  `(list t)` first. `c-add-local-hook` reproduces that by hand (the
  tree's `add-hook` has no LOCAL arm); do not simplify it to a `cons`.
* **`c-valid-offset`'s vector arm needs `vector-length`** - Guile's
  `length` is lists only, and the fallback offset table's `cpp-macro`
  entry is Emacs's own `[0]`. Every `c-set-style` installs the fallback
  table, so this is reached on the first call.
* **`c-get-style-variables` merges the fallback first**, so `gnu`'s
  `c-basic-offset` reads 4 from the merged alist while `c-set-style`
  applies 2 afterwards. That duplicate is measured Emacs behaviour.
  An undefined style reports through `c-benign-error` and resolves to
  the fallback; the Emacs `(cdr nil)` there is `%c-cdr`.
* **`adaptive-fill-regexp`'s default in fill.scm was an older Emacs's
  value** (`"[ \t]*\\([-…]+\\)?[ \t]*"`); Emacs 31.1's is
  `"[-–!|#%;>*·•‣⁃◦ \t]*"` (`fill.el:104`). It is shared by every
  adaptive fill and embedded by `c-setup-paragraph-variables`, and the
  corrected default is what makes the CC paragraph variables match.
* **The six paragraph/fill variables `c-setup-paragraph-variables`
  writes are parameter + buffer-local accessor pairs** (the previous
  pass's open question); the CC setup cannot leak across buffers.

Test-harness notes: `c-init-language-vars` expands into `cc-langs`
internals, so a test that imports only `c-init-language-vars` fails
with `Unbound variable: c-lang-set-local!` at the first call - import
`(schemacs progmodes cc-langs)` wholesale (as `cc-vars-tests` does). And
`srfi 64` catches errors raised inside a test form and reports them as
`actual-error`, so an unbound name in a test reads as a failure rather
than killing the suite - useful, and one more reason to read the whole
failure block.

Verified: all **91 suites** pass (exit 0), `cc-styles-tests` 60,
`cc-vars-tests` 32, `cc-fonts-tests` 60, `fill-tests` 39, `fns-tests`
41, `subr-tests` 104 - and the pty battery is **100/100** on the
settled tree, run alone.

Next, unchanged: `cc-mode.el` - the mode definitions, `c-before-change`/
`c-after-change`, `c-font-lock-init`, with `easy-menu-define` and a
`def-edebug-spec` stub as the two missing primitives - then the first
milestone: `.c`/`.h` opening in c-mode through `auto-mode-alist`, faces
compared to Emacs.

## cc-mode step 7: the indentation analysis (2026-11-23)

`cc-engine.scm` now has cc-engine.el's final section - `c-add-syntax`,
`c-add-stmt-syntax`, `c-add-class-syntax`, `c-guess-continued-construct`,
`c-guess-basic-syntax`, `c-evaluate-offset`, `c-calc-offset`,
`c-get-offset`, `c-get-syntactic-indentation` - and the pieces it stands
on that the earlier tranches had skipped: `c-looking-at-inexpr-block-
backward`, `c-beginning-of-inheritance-list` and the three C++20 concept
walkers. The `c-langelem-*` accessors moved into cc-defs.

**The gate is `tools/cc-cgbs-diff/`**: both trees print
`(POSITION SYNTAX)` at every line start and `diff` them, in `c-mode` or
`c++-mode` with the gnu style. It is **identical on 8 fixtures** - the
one in that directory, the four C and three C++ ones under
`tools/cc-decl-diff/`. `cc-engine-tests` grew the `guess` group (20
Emacs-measured rows from the fixture, plus two brace-list rows) and the
`offsets` group (17 rows for `c-evaluate-offset`'s number/vector/nil/
`+ - ++ -- * /`/min/max/add/first/quote arms and
`c-get-syntactic-indentation`'s two anchors).

What this pass cost, all of it recorded in DEPARTURES.md:

* **`set!` is not `setq`.** About twenty `(set! X ...)` uses in *test*
  position returned Guile's unspecified value (truthy; once zero values,
  which raises) instead of Emacs's new value. Each is
  `(begin (set! X e) X)` now. Grep a ported condition for `(set!` before
  believing it.
* **A `cond` with no `else` is true.** CASE 5A.3's inner cond has no
  else in Emacs; in Scheme that is an always-true test and a stale
  placeholder (`(brace-list-open #t)`).
* **A balanced file can be the wrong shape** - the CASE 18 body was
  inside its test by one paren, compensated at the clause's end. Dump
  the parsed clause and compare its operand heads; per-clause reader
  checks localize it.
* **Nil tests on lists**: `(if paren-state ...)` and `(and state-cache
  (pair? (car state-cache)))` need `pair?`; `(car paren-state)` needs
  `car-safe`.
* **Operand order**: `(> (point) (progn ...))` reads point before the
  progn in C; bind it first.
* New primitives: `/=` (data), `rassq`/`rassoc` (fns). The line-up
  function registry (`c-register-lineup-function!`) is the stand-in for
  Emacs's `(functionp SYMBOL)`, empty until cc-align.

The harness's mode replay, for reuse: `major-mode`, `parse-sexp-
ignore-comments`, the language vars, the syntax table, the gnu style,
`c-clear-found-types`, `c-make-noise-macro-regexps` and
`c-make-macro-with-semi-re` (the mode's `:after-hook`). A missing noise
regexp reaches `(looking-at #f)`; a missing `c-clear-found-types`
reaches `hash-for-each` on `#f`.

Verified: full suite battery 91/91 (exit 0) and `tools/pty-check.py` run
alone on the settled tree (see the commit message for its count).

Next, in the approved order: **cc-align** (the line-up functions and the
registrations the offset evaluator waits for), then **easymenu**,
**cc-cmds**, **cc-menus/cc-guess**, and **cc-mode.el** - then the
`.c`/`.h` milestone.

## cc-mode step 8: cc-align, the line-up functions (2026-11-23)

`schemacs/progmodes/cc-align.scm` is `cc-align.el` whole, in the file's
order with its docstrings, and the offset evaluator's registry is
filled at the end of it. DEPARTURES.md's 2026-11-23 "cc-align" section
has every representation departure and the primitives the port needed;
this is what the next session needs.

## The two differentials, which are the gate

* `tools/cc-indent-diff/` - `c-guess-basic-syntax` +
  `c-get-syntactic-indentation` per line start, both sides, under ten
  styles on the nine fixtures: **90 runs, zero differences**. A style
  picks the line-up functions its offsets name, so this is what
  exercises most of the file. README has the three commands.
* `tools/cc-align-diff/` - each function called **directly** with
  `c-syntactic-element`/`c-syntactic-context` bound, on the constructs
  the styles do not reach (assignments, ternary, cascaded calls, string
  continuation, argcont, gcc asm, templates, lambda, the brace-list
  ones, the semi&comma criteria, gnu-min): **51 probes identical**,
  including four where Emacs itself raises.
  `test/progmodes/cc-align-test.scm` pins every probe's answer (55
  tests).

A case table locates positions by **needles** (a substring plus a
character delta) in both harnesses, so the same table works on both
sides without position bookkeeping. Contexts are elements too: a
`c-syntactic-element` is `(SYM ANCHOR SECOND)` - the second position is
the arglist's open paren, which is what `c-langelem-2nd-pos` is for.

## The three bugs worth carrying

1. **A local named `quote` shadows the reader's `'` syntax.** Emacs's
   `c-lineup-string-cont` binds a variable `quote`; in Scheme, inside
   that `let`, `(c-point 'boi)` reads as a *call* of the variable and
   the compiler warns "possibly unbound variable `boi'". It is
   `quote-char` here.
2. **Elisp's `if` takes several ELSE forms.** Three functions use them;
   each is a `begin` in Scheme's else.
3. **The semi&comma answer shape** is `(if CONDITION t 'stop)` - the
   caught error answers `t` as well, and only a successful up-list at a
   `(` answers `stop`. The first port had the arms swapped, which the
   direct probe caught at once.

## `forward-word` was mg's, and is now `syntax.c`'s

`c-lineup-java-inher` calls `forward-word-strictly`, and that exposed
that the tree's `forward-word` had none of the DEFUN's semantics. The
full port is described in DEPARTURES; the things to know:

* `syntax.scm` now has `forward-word` (`"^p"`), the boundary table
  (honoured by `%scan-words`), and both strict variants (a placement
  departure: `subr.scm` is below and cannot call it).
* `%scan-words` answers **0** when it runs out of buffer, as the C does;
  its callers treat 0 as "stop at the edge".
* `constrain-to-field` arrives through
  `*constrain-to-field-function*`, installed by `editfns.scm`.
* `simple.scm`'s `backward-word` is `simple.el`'s one line, and
  `transpose-words` passes `forward-word` as its mover again.
* A test harness (or any code) that calls a line-up function with
  language-dependent internals must have `*c-buffer-is-cc-mode*` bound
  while it runs - `cc-align-tests.scm` binds it per case, which the
  first version did not, and `c-lineup-inexpr-block` answered `#f`.

Next, in the approved order: **easymenu** (the one primitive cc-mode.el
needs for its eight menus), **cc-cmds**, **cc-menus/cc-guess**, and
**cc-mode.el** - then the `.c`/`.h` milestone.

## cc-mode step 9: easymenu, and the separator it corrected (2026-11-23)

`schemacs/core/easymenu.scm` is `lisp/emacs-lisp/easymenu.el` whole,
in the file's order with its docstrings, and it is in `loadup.scm` and
`imports.scm`. DEPARTURES.md's 2026-11-23 easymenu section has every
representation departure; this is what the next session needs.

## The verification

`tools/easymenu-diff/` compares `easy-menu-convert-item` on 18 item
specs - every keyword a `easy-menu-define` item takes - plus
`easy-menu-always-true-p` and `easy-menu-name-match`, with Emacs 31.1's
answers: **identical**. `test/core/easymenu-test.scm` (52 tests)
pins those answers and the define/add/change mechanics Emacs measured on
a real definition: the variable's prompt, the downcased
`[menu-bar test]` binding, the written display order, add-at-end,
add-BEFORE, present/remove, `easy-menu-change` replacing a submenu, the
`:visible nil` invisible menu, and the `:filter` box.

## The bug the differential found in existing code

**`menu-bar-separator` was wrong.** `menu-bar.scm` had
`'(menu-item "--")` with a comment claiming that was Emacs's value;
Emacs 31.1's `(require 'easymenu)` then `menu-bar-separator` answers
`("--")` - `subr.el:7700`'s `(defconst menu-bar-separator '("--"))`,
the old-style `(STRING . DEFN)` binding. It is in `subr.scm` now (its
Emacs home), `menu-bar.scm` imports and re-exports it, and
`menu-bar-menus-tests.scm` pins the corrected value.

## A hazard for every future reader of a keymap's bindings

`store-in-keymap` writes the bindings hash with `hashv-set!`, and a
*generic* `hash-ref`/`hash-remove!` on that table looks in a different
bucket: after `(hashv-set! t 'A 1)`, `(hashv-ref t 'A)` is 1 and
`(hash-ref t 'A)` is `#f`; `hash-remove!` left a removed menu item
live, which is how this was found. Read and write the bindings with the
`hashv` family (`easymenu` does; `%keymap-remove-binding!` is
`hashv-remove!`). The same rule applies to every `make-hash-table` here
that is written with a family accessor: stay in that family.

## The Lisp-1 name split, and how easymenu spells Emacs's two-namespace name

Emacs `defvar`s `c-c-menu` (the menu) and `defalias`es `c-c-menu` (the
popup command). One Scheme binding cannot be both: the binding is the
menu and the command is registered in the command table under the
menu's name (docstring and name via `set-procedure-property!`). Emacs
hides these commands from M-x with a completion-predicate; this tree
lists them - a named departure.

## Next

**cc-cmds** (5,190 lines): the editing commands, including the
`c-electric-*` family the electric discussion in this file is about
(`c-electric-brace`, `-semi&comma`, `-colon`, `-slash`, `-star`,
`-lt-gt`, `-paren`, `-backspace`, `-delete-forward`), their
`c-hanging-*` machinery, and `c-indent-line`'s command layer - then
**cc-menus/cc-guess** and **cc-mode.el**, then the `.c`/`.h` milestone.

`c-electric-flag`/`c-auto-newline`/`c-hungry-delete-key` are already in
(cc-engine buffer-locals) and `c-electric-flag` defaults `#t`;
`electric-indent-mode` does not exist here, so `c-basic-common-init`'s
`(setq electric-indent-inhibit t)` and the two sync hooks wait for it -
record that as a named departure when cc-mode.el lands.

# Handoff - cc-mode step 10: cc-cmds' indentation command layer
# (2026-11-23)

`schemacs/progmodes/cc-cmds.scm` is new: `c-indent-line`,
`c-newline-and-indent`, `c-show-syntactic-information`,
`c-syntactic-information-on-region`, `c-update-modeline`, the six
toggles, `c-indent-command`, `c-indent-exp`, `c-indent-region`,
`c-fn-region-is-active-p`, `c-indent-line-or-region`, the progress
helpers and the `c-backslash-region` family - with the prerequisites
that had to land first (see DEPARTURES.md's same-day section). The
electric keys, the motions, the defun/declaration cluster and the
filling half are the next tranches; the file header lists them.

## Before touching it

* **`cc-cmds-tests.scm` (26) is every test passing.** Each edits a
  *fresh* buffer - one edit per buffer - because cc-mode's caches are
  not invalidated between edits yet (see below). The expectations are
  Emacs 31.1's, measured first.
* **A replay must set what `c-basic-common-init` will**: the mode's
  `indent-line-function` (else `c-indent-command` calls
  `indent-relative` and silently does nothing), the syntax table, the
  language vars, the style - and `c-block-comment-flag` if the mode
  line's `*` matters.
* **`c-run-special-indent-hook` resolves the style hook's *symbols***:
  a test (or a session) that never loads `(schemacs progmodes cc-align)`
  has an empty line-up registry, so `c-gnu-impose-minimum` does
  nothing. Import it.
* **`set!` in a `while`/`and` test**: `c-indent-exp` hung on
  `(and (set! beg ...) (set! end ...))` - a `set!` answers the
  unspecified value, so the loop never stopped. Write
  `(begin (set! x e) x)` wherever the C's `setq` value is the test.
  This is the same class as the earlier `(set! ...)`-in-test fixes
  and it cost a real hang here.
* **`#{1+}#`/`#{1-}#`**: `1+` is Guile core but not imported by a
  library; the compiler's warning is the only evidence. `(+ x 1)`.

## The real gate: cc-mode.el's change hooks

`c-indent-line` edits the buffer. cc-mode invalidates its caches - the
literal-position cache, the parse-state cache, the syntactic-whitespace
ladder - from `c-before-change`/`c-after-change`, which
`c-basic-common-init` installs on the two change-hook lists. **Neither
is ported**, so the whole-buffer differential
(`tools/cc-cmds-diff/`) is 75/99 and every difference is on a fixture
where one line's reindentation changes the next line's parse. Its
README has the diagnosis and the simulation that confirms it.

So the next step in the approved order is **`cc-mode.el`'s change
functions** (`c-before-change`, `c-after-change` and the pieces they
call that are not yet here: `c-unfind-enclosing-token`,
`c-unfind-coalesced-tokens`, `c-before-change-de-typedef`,
`c-clear-char-property-with-value`, `c-get-state-before-change-functions`,
`c-just-done-before-change`, the ml-string fence machinery), then the
electric keys, then the motions and the filling half. `cc-mode.el`'s
mode definitions (`c-basic-common-init`, `c-common-init`, the derived
modes) follow, and with them the `.c`/`.h` milestone.

## Also landed

The two cc-engine bug fixes are in the DEPARTURES section above
(`c-add-stmt-syntax`'s set!-in-test, `c-invalidate-state-cache`'s lost
`here`). `imports.scm` is regenerated (118 libraries, 4892 names) and
`loadup.scm` carries cc-cmds.

# Handoff - cc-mode step 11: cc-mode.el's found-type change helpers
# (2026-11-23)

`schemacs/progmodes/cc-mode.scm` (new, partial) has the found-type half of
`cc-mode.el`'s change machinery: `c-unfind-enclosing-token`,
`c-unfind-coalesced-tokens`, `c-before-change-de-typedef`,
`c-after-change-de-typedef`, `c-update-new-id` and
`c-just-done-before-change`. `cc-mode-tests.scm` is 13, every
expectation Emacs 31.1's (measured first), and all cc suites plus
loadup-tests are green. `imports.scm` regenerated (119 libraries, 4899
names).

**The buffer-local flags this file touches are cc-engine's**:
`c-maybe-stale-found-type` and `c-new-id-start/end/is-type` live there
(the found-type table reads them); cc-mode imports them. Do not
redefine them here - `loadup-tests`' clash census will catch it, and
until it did the second copy was what the two libraries disagreed
about.

**What remains of the change machinery**, in dependency order, is the
string-fence layer first (`c-put-syn-tab`/`c-clear-syn-tab` and their
`c-fl-syn-tab` mirrors, the `c-min-syn-tab-mkr`/`c-max-syn-tab-mkr`
pair, `c-put-string-fence-trim-caches`/`c-clear-syntax-table-trim-caches`,
`c-restore-string-fences`/`c-clear-string-fences`, then
`c-before-change-check-unbalanced-strings`,
`c-after-change-mark-abnormal-strings`,
`c-after-change-escape-NL-in-string` and the ml-string functions);
then `c-depropertize-CPP`, `c-neutralize-syntax-in-CPP`, the
comment-escape and quote pairs, `c-extend-font-lock-region-for-macros`
and `c-change-expand-fl-region`; then `c-before-change`/`c-after-change`
themselves; then `c-basic-common-init`/`c-common-init` and the mode
definitions, which is when `.c` files start opening in c-mode and the
`tools/cc-cmds-diff/` differential's 24 red pairs can be closed.

**`c-called-from-text-property-change-p` needs a decision**: Emacs
asks `(cadr (backtrace-frame 3))` whether the invoking primitive was
`put-text-property`/`remove-text-properties`/`remove-list-of-text-properties`.
Guile has no `backtrace-frame`; the tree's property writers are its
own, so the pass that needs it should bind a flag in the
property-change path (textprop.scm) and read it there, rather than
imitating a backtrace.

## RESUME HERE after the file rename (2026-11-23)

The layout change is done and the notes above were rewritten to the new
paths: `schemacs/editor/X.scm` is now at its Emacs-mirroring path (`schemacs/X.scm` for `src/*.c`,
`schemacs/core/X.scm` for `lisp/emacs-lisp`, `schemacs/progmodes/X.scm`,
`schemacs/international/X.scm`, `schemacs/textmodes/X.scm`,
`schemacs/term/X.scm`), the tests are under `test/` mirroring the
library tree with `-test.scm` names, and the libraries are named by
their new paths (`(schemacs progmodes cc-engine)` etc.). `schemacs/core/
syntax-macros.scm` is the old `(schemacs core syntax-macros)` macro library
(Emacs's `subr.el` control macros); `schemacs/syntax.scm` is `src/syntax.c`
(formerly `(schemacs editor syntax)`), and its `syntax.el` half rides with
it, as that library's header explains.

**cc-mode resume point, exactly:**

1. `schemacs/progmodes/cc-mode.scm` is the partial cc-mode.el: the
   found-type helpers (`test/progmodes/cc-mode-test.scm`, 13 tests) and
   **the string-fence layer** - `c-put-syn-tab`/`c-clear-syn-tab`, the
   `c-min-syn-tab-mkr`/`c-max-syn-tab-mkr` pair,
   `c-clear-string-fences`/`c-restore-string-fences`,
   `c-multiline-string-check-final-quote` and
   `c-remove-string-fences` - with `c-with-string-fences`' two seams
   installed at load (22 tests now). The Emacs-measured differential
   is in DEPARTURES.md's 2026-11-23 "string-fence layer" section; the
   unit group is `schemacs_editor_cc_mode_fences`. The
   `*-trim-caches` wrappers live in `cc-engine.scm` (a name-placement
   departure: their last form is cc-engine's cache truncator).
   **The bug that pass found**: five cc-defs property searches returned
   the *unspecified* value (true) on failure where Emacs's `when`
   answers nil; `c-clear-string-fences`'s "already unbalanced" test
   then fired on failure. They are explicit `(if ... #f)` now.
   **The three string change functions are in too** - `c-before-change-
   check-unbalanced-strings`, `c-after-change-mark-abnormal-strings`,
   `c-after-change-escape-NL-in-string`, with `c-pps-to-string-delim`,
   `c-unescaped-nls-in-string-p`, the two state variables and, in
   cc-engine, the ml-string propertization for C++ raw strings
   (`c-maybe-re-mark-ml-string` and its two callees). The differential
   table is in DEPARTURES.md; the unit group is
   `schemacs_editor_cc_mode_string_changes` (16). **A bug fixed on the
   way**: `c-get-ml-closer` applied a language variable that holds a
   function *symbol* - always resolve through `(%c-lang-function
   (%c-langvar 'NAME))`.
   **The include-<> and comment-escape pairs are in too**
   (`c-before-change-include-<>` / `c-after-change-include-<>`, and
   `c-before-change-fix-comment-escapes` /
   `c-after-change-fix-comment-escapes`), with the
   bug that `(not (cdr LIST))` is false in Scheme - use `(null? (cdr
   ...))` - caught by their differential; the group is
   `schemacs_editor_cc_mode_include_comment_escapes` (9). The dumps
   differ only where Emacs's mode initialisation has already marked
   things, which this tree has no counterpart for yet.
   **The quote parsing is in too** (`c-quoted-number-*`,
   `c-parse-quotes-before/after-change`; the group is
   `schemacs_editor_cc_mode_quotes`, 11), verified by an all-position
   differential. Its `(search-forward ... 'limit)` exposed the
   NOERROR rule now fixed in `search.scm` (point moves to the limit for
   any non-nil NOERROR but `t`).
   **Half the ml-string machinery is in** (`cc-engine.el:7549`-`:7862`:
   `c-depropertize-ml-string-delims`, `c-ml-string-opener-intersects-region`,
   `c-ml-string-delims-around-point`, `c-position-wrt-ml-delims`, and the
   `c-clear-syntax-table-properties-trim-caches` wrapper; group
   `schemacs_editor_cc_engine_ml_delims`, 8). Two traps are in
   DEPARTURES.md: `(null? #f)` is false (use `(or (not X) (null? X))`),
   and a while's *search conjunct* must not be stored in the loop
   variable or a failed search re-reads stale match data and spins.
   **The depropertize family is in** (`c-depropertize-ml-string`,
   `c-depropertize-ml-strings-in-region`,
   `c-before-after-change-check-c++-modules`, plus the two global
   neutralize variables; group
   `schemacs_editor_cc_engine_ml_depropertize`, 4).
   **The ml-string state and helpers are in too** (the seven global
   state variables, `c-ml-string-back-to-neutral`,
   `c-clear-syn-tab-properties` with its seam - the cc-mode body is
   `%c-clear-syn-tab-properties-full`, because two exports of one name
   are two bindings and `loadup-tests` refuses that).
   **`c-ml-string-in-end-delim` is in** (`cc-engine.el:7670`, right
   after `c-ml-string-back-to-neutral`; group
   `schemacs_editor_cc_engine_ml_end_delim`, 7 rows, every Emacs
   31.1's). Its final `unless` is a value, so it is an `if` with an
   explicit `#f` - left as `unless` the nil rows answered the
   unspecified value. `(match-data)` answers nil (not `'()`) when
   nothing has been searched.
   **The two ml-string change functions are in**
   (`c-before-change-check-ml-strings` `:7863`,
   `c-after-change-unmark-ml-strings` `:7953`, with the two opener-re
   builders and a `*c-remove-string-fences-function*` seam that
   cc-mode installs). A 34-row differential over five fixtures is
   identical; group `schemacs_editor_cc_engine_ml_change` pins 12.
   Three bugs: a pre-existing `when` in value position in
   `c-depropertize-ml-strings-in-region`, two Emacs car/cdr-of-nil
   arms (`%c-car`/`%c-caddr`), and **`match-data` answering `'()`
   where Emacs answers nil** - fixed in `search.scm`.
   **The property-change test and the CPP propertizers are in**
   (`cc-mode.el:997`-`:1260`; group `schemacs_editor_cc_mode_cpp`, 13).
   `c-called-from-text-property-change-p` is a parameter
   (`*in-property-change-p*`, bound in `textprop.scm`'s
   `modify-text-properties`) where Emacs walks its stack; the
   after-change side of Emacs's signal is a named gap.
   **`c-before-change` is in** (`cc-mode.el:2224`), with the language
   function registry filled for both libraries' members. Its port fixed
   a pre-existing arity departure (`c-invalidate-state-cache` takes no
   argument in Emacs) and found two bugs: literal states read with
   plain `cadr`/`caddr` (a one-element answer crashes `(car '())` -
   `%c-cadr`/`%c-caddr` now) and `c-invalidate-macro-cache`'s
   `(cdr cache)` nil test, which needs `%c-true` (the cdr is normally a
   *number*). Eight-row real-hook differential identical; group
   `schemacs_editor_cc_mode_before_change`, 6.
   **The fl-decl pair and `c-change-expand-fl-region` are in**
   (`cc-mode.el:2448`-`:2665`; group
   `schemacs_editor_cc_mode_fldecl`, 13). A 370-row whole-position
   differential is identical. The objc helper is a signalling stub (no
   objc-mode here). **Harness note**: `c-major-mode-is` reads
   `*c-buffer-is-cc-mode*`, so a direct-call probe must parameterize
   it - without that `c-forward-declarator` answers #f everywhere and
   the port looks broken.
   **`c-after-change` is in** (`cc-mode.el:2364`), with the
   `c-in-after-change-fontification` accessor pair; seven-edit
   two-hook differential identical; group
   `schemacs_editor_cc_mode_after_change`, 4. Two bugs: the sws
   `-after-del`/`-ins` helpers answered the unspecified value into
   `max` (fixed with `when-e`), and the flush was written
   `(syntax-ppss-flush-cache (c-syntax-table-hwm))` - c-syntax-table-hwm
   is a *plain variable*, so that applied a number.
   **The defun movements are in** (`cc-cmds.el:1569'-`:2426'`, plus
   `c-indent-defun`), placed in Emacs's file order inside
   `cc-cmds.scm`. The gate is
   `tools/cc-cmds-diff/emacs-defuns.el` / `ours-defuns.scm`: ten
   probes at every position, identical on ten fixtures in both
   languages, `c-indent-defun`'s resulting text included. Two things
   the harness must do (README): import
   `(schemacs progmodes cc-align)` (the gnu style's
   `c-gnu-impose-minimum` moves labels off column 0), and run the
   editing probe in its own fresh buffer. A replay of the mode must
   call `c-make-noise-macro-regexps` and `c-make-macro-with-semi-re`
   (the mode's `:after-hook`) or `c-forward-sws` looks up a #f regexp.
   **The statement, sentence, comment-indent and conditional commands
   are in too** (`cc-cmds.el:2429'-`:3531'`, plus `c-sentence-end` in
   `cc-defs`). The gate is
   `tools/cc-cmds-diff/emacs-stmt.el` / `ours-stmt.scm`: twenty-two
   probes at every position, identical on eight fixtures in both
   languages; `cc-cmds-tests.scm`'s `schemacs_editor_cc_cmds_statements`
   group pins 13 rows plus the clean `c-scan-conditionals` table. Two
   nil-answer bugs were found and fixed: the style accessor's `()` must
   be tested with `%c-true`, and two `cond`s in value position need
   `(else #f)`.
   Next is the rest of cc-cmds, which `c-basic-common-init` waits on:
   the filling half (`cc-cmds.el:4057'-`:5152`:
   `c-indent-new-comment-line`, `c-context-line-break`/`-open-line`,
   `c-fill-paragraph`, `c-do-auto-fill`, `c-mask-paragraph`,
   `c-guess-fill-prefix`), then the electric keys
   (`:409'-`:1568'`, with the file's `put 'delete-selection` block).
   After that `c-basic-common-init`/`c-common-init`/`c-font-lock-init`
   (whose `c-setup-doc-comment-style` is what sets `c-doc-line-join-re`
   for real sessions) and the mode definitions.
3. Then `c-basic-common-init`/`c-common-init` and the mode definitions
   (with `c-font-lock-init`/`c-font-lock-fontify-region`, and the
   language function registry filled for every symbol the change
   lists name).
   That is the gate for `tools/cc-cmds-diff/`: currently 75/99, every
   red pair a stale cc cache. Run it with:
   `emacs -Q --batch -l tools/cc-cmds-diff/emacs-cmds.el STYLE FILE OUT [cpp]`
   and `guile --no-auto-compile -L . -L "$SITE" -s tools/cc-cmds-diff/ours-cmds.scm STYLE FILE OUT [cpp]`
   over the fixtures in `tools/cc-decl-diff/`, `tools/cc-cgbs-diff/`
   and `tools/cc-align-diff/`.
4. `cc-engine.scm`, `cc-cmds.scm`, `cc-fonts.scm`, `cc-align.scm`,
   `cc-styles.scm` and `cc-langs.scm` are otherwise the verified state:
   the per-line indentation differential (`tools/cc-indent-diff/`) and
   the other cc differentials are green.

Right-sized verification for a cc-only change: `test/progmodes/cc-*`,
`test/progmodes/cc-*-test.scm`, `test/loadup-test.scm`, plus
`python3 tools/pty-check.py imports scratch`.

# Handoff - cc-mode: the filling half of cc-cmds (2026-11-24)

The paragraph-filling half of `cc-cmds.el` is ported and verified:
`c-guess-fill-prefix`, `c-mask-paragraph`, `c-fill-paragraph`,
`c-do-auto-fill`, `c-indent-new-comment-line` (with the
`c-comment-line-break-function` alias), `c-context-line-break` and
`c-context-open-line`, plus `c-delete-and-extract-region` in
`cc-defs.scm`. The differential is `tools/cc-fill-diff/` (README has
the commands and the results); `c-fill-paragraph` and
`c-guess-fill-prefix` are exact at every position of four fixtures,
and the other three commands agree except in two transient states,
named with static reproducers at the end of DEPARTURES.md's
"cc-mode: the filling half" section - both are `c-guess-basic-syntax`
answer differences at states the command creates (`cpp-define-intro`
inside a braced `#define` body, and `/x` splitting a comment starter),
not filling-code bugs.

**Compile `schemacs/progmodes/cc-cmds.scm` at optimization level 1.**
Guile 3.0.11 miscompiles `c-append-backslashes-forward` at the default
level (2): a compiled build segfaults in `vm_regular_engine` when point
is on a string literal's backslash-continued line. Levels 0/1 are
correct; the crash is on HEAD before this work too. The Makefile has an
explicit `#:optimization-level 1` rule for that file; a hand compile
must pass `#:optimization-level 1` too. Every other library stays at
the default. DEPARTURES.md has the evidence.

Four primitive bugs the differential found, each fixed at its own
level: a **parameter's setter answers the OLD value** (measured; the
`setq`-as-value analogue - `c-query-and-set-macro-start`), **Elisp's
`(symbolp nil)` is true and `(symbol? #f)` is not** (the macro-start
cache), **`set!` as the last `and` operand returns zero values** (four
sites in `c-guess-basic-syntax`), and **`skip-chars-*`'s BOUND takes a
marker** (`CHECK_FIXNUM_COERCE_MARKER`, `c-backslash-region`'s crash).
`delete-horizontal-space`'s BACKWARD-ONLY is optional now.

State after this tranche, in the approved order:

1. **The electric keys** (`cc-cmds.el:409'-`:1568'`): every
   `c-electric-*` command and the `c-hanging-*` machinery they drive
   (`c-point-syntax', `c-brace-newlines', `c-try-one-liner',
   `c-do-brace-electrics'), the file's `put SYM 'delete-selection`
   block, and then `c-post-text-conversion` (`:5152'), which is a
   dispatch over them. `c-electric-flag`/`c-auto-newline`/
   `c-hungry-delete-key` and `c-syntactic-indentation-in-macros' are
   already in cc-engine.
2. `c-basic-common-init`/`c-common-init`/`c-font-lock-init` and the
   mode definitions (with `c-setup-doc-comment-style`, the
   `electric-indent-inhibit` named departure, and `easy-menu-define'
   still the one missing primitive for cc-mode.el's menus), then the
   `.c`/`.h` milestone and driving `tools/cc-cmds-diff/` to 99/99.
3. The two residual engine differences above, as a cc-engine pass
   using the static reproducers (`fixture-transient108.cpp` and the
   `#define` body case).

`test/progmodes/cc-cmds-test.scm` is 63 tests (a filling group of 19
plus the existing groups), `test/syntax-test.scm` gained the
`skip_chars_bound` group, `imports.scm` is regenerated, and the full
suite and pty batteries were run on the settled tree (see the commit
message for their counts).

# Handoff - cc-mode: the electric keys (2026-11-24)

`cc-cmds.el:409-1568` is ported: every `c-electric-*` command, the
`c-hanging-*` machinery they drive (`c-point-syntax`,
`c-brace-newlines`, `c-try-one-liner`, `c-do-brace-electrics`), the two
hungry deletes, the file's `put SYM 'delete-selection` block, and
`c-post-text-conversion` (`:5152`). The gate is
`tools/cc-electric-diff/`: **60 scenarios against Emacs 31.1, 0
different, 1 known** (`brace-elseif`, explained there and in
DEPARTURES.md's "cc-mode: the electric keys" section).

## What the next session needs

- **`c-tentative-buffer-changes` is new in cc-defs** and is how
  `c-try-one-liner`/`c-point-syntax` undo their probe edits: it writes
  the buffer's own undo list (the tree has no `buffer-undo-list`
  binding), keeps the changes when the body's value is true, otherwise
  `primitive-undo`s back to the saved tail, then restores
  point/mark/active/modified. The body must edit the entry buffer.
- **`c-end-of-defun-1` lives in cc-engine** (beside
  `c-beginning-of-defun-1`, whose scan it shares - a named placement),
  and `c-point`'s `'bod`/`'eod` now work.
- **`c-benign-error` moved to cc-defs** (its Emacs home); cc-engine
  re-exports it.
- **A key event is an integer.** `c-last-command-char` answers the
  integer byte code; Emacs's `?X` names the same integer, Scheme's `#\X`
  is a different object. Four `c-semi&comma-*` criteria in cc-align
  compared against `#\;` and were **always false** - fixed with
  `(char->integer #\;)`, and the align test's probe now binds the
  integer event. Any future port comparing against a character literal
  is suspect.
- The C++ brace scenario exposed a pre-existing zero-values bug in
  `c-guess-basic-syntax` CASE 5A.3 (a `set!` as a clause's value);
  fixed, and `tools/cc-cgbs-diff/` still passes.

## The two things to do in the approved order

1. **The `c-laomib-fix-elt` bug**: with the mode's change hooks
   (`c-before-change`/`c-after-change`) installed, the C++ brace
   scenarios raise there - `(cdr '())` where Emacs's `(cdr nil)` is
   nil - in the bracelist machinery. It is real and the electric path
   reaches it. Fix it in its own cc-engine pass and re-run
   `tools/cc-decl-diff/`'s bracelist fixtures. The electric harness
   deliberately stays hook-free until then, which is also why
   `brace-elseif` is its one known difference (Emacs's mid-command
   hooks; a static `c-indent-line` gives 2 in both editors).
2. **cc-mode.el**: `c-basic-common-init`/`c-common-init`/
   `c-font-lock-init`, the mode definitions, with `easy-menu-define`
   still the one missing primitive (cc-mode.el's menus) and a
   `def-edebug-spec` stub; then re-point the electric harness at the
   real mode, install the hooks, close `brace-elseif`, and drive
   `tools/cc-cmds-diff/` to 99/99. Then the `.c`/`.h` milestone.

## Verified

`test/progmodes/cc-cmds-test.scm` is 106 (groups 26 + 10 + 13 + 32 +
21 + 4), `cc-engine-test` 629, `cc-align-test` 55, and every other cc
suite passes; `schemacs/imports.scm` is regenerated (125 libraries,
5099 names) and `python3 tools/pty-check.py imports scratch` is 2/2.
`cc-cmds.scm` compiles at `#:optimization-level 1` (the Guile 3.0.11
miscompile rule still applies).

# Handoff - cc-mode: the change hooks on, and the seven defects they
# exposed (2026-11-24)

The electric tranche's harness now installs the mode's change hooks,
and the cc-cmds indentation differential went from **75 of 99
fixture/style pairs to 99 of 99**. Seven real defects fell out, all
recorded in DEPARTURES.md's section of this date:

1. `c-laomib-fix-elt` ran off a nil paren-state (`'()` is true in
   Scheme where Emacs's nil is false; the reads are `%c-cadr` now).
2. `c-add-stmt-syntax` filled in the anchor *inside* its go-out gate;
   Emacs does it once after the loop. `(statement-block-intro #f)` and
   the `else if` indent (2 vs 3) were the symptom.
3. `c-guess-continued-construct`'s CASE G compared a character with
   `/=`.
4. `c-looking-at-inexpr-block`'s compound-literal arm was a stale
   signalling stub; it is the C's expression now.
5. Two `when`s in `c-clear-<-pair-props-if-match-after`/
   `c-clear->-pair-props-if-match-before` answered the unspecified
   value where Emacs answers nil, and a caller's `setq` read it.
6. `car-safe`/`cdr-safe` in `subr.scm` answered `'()` for a non-cons -
   true in Scheme - where Emacs answers nil; `c-lineup-comment`'s
   `(or (cdr-safe offset) ...)` took the empty list and the
   comment-intro offset came out 0 instead of -1000. Both answer `#f`
   now (shared primitive: the full batteries were run).
7. `c-indent-new-comment-line`'s `comment-text-end` had an `if`
   without an `else` in value position; the unspecified value is true
   and `(> (point) #<unspecified>)` raised in `c-context-open-line`.

## What a replay must do, learned the hard way

- **Bind `*c-buffer-is-cc-mode*` for the whole run**, not just the
  setup. It is a buffer-local in Emacs (set by `c-basic-common-init`);
  here it is a parameter, and a C++ branch (`public slots:` as
  `access-label`) silently takes the other arm when it is unbound.
- **Install `c-before-change`/`c-after-change`** around any command
  that edits repeatedly (`c-indent-region`): the caches are
  invalidated from those hooks.
- `tools/cc-cmds-diff/ours-cmds.scm` and
  `tools/cc-electric-diff/ours-electric.scm` do both now;
  `tools/cc-cmds-diff/README.md` and `tools/cc-electric-diff/README.md`
  say why.

## Verified

`tools/cc-cmds-diff/` 99/99; `tools/cc-indent-diff/` 84/84;
`tools/cc-cgbs-diff/` 10 fixtures identical; `tools/cc-decl-diff/`
8 fixtures identical; `tools/cc-electric-diff/` 60 scenarios, 0
different (`known.txt` empty). `tools/cc-fill-diff/` is unchanged from
its documented state apart from defect 7's two improvements; its
current-vs-baseline run is identical. The `cc-*` suites pass
(`cc-engine-tests` 629, `cc-cmds-test` 106, `cc-align-test` 55,
`cc-mode-test` 110), and the full suite and pty batteries were run on
the settled tree (see the commit message for the counts).

## Next

`cc-mode.el`: `c-basic-common-init`/`c-common-init`/`c-font-lock-init`
and the mode definitions, with `easy-menu-define` still the one missing
primitive for its menus and a `def-edebug-spec` stub; then the
`.c`/`.h` milestone (auto-mode-alist). The remaining fill item is
`c-indent-new-comment-line`'s macro branch returning what
`c-newline-and-indent` does (nil vs unspecified) - named in the fill
README.

# Handoff - cc-mode.el recon, before the mode tranche (2026-11-24)

The next tranche is `cc-mode.el`'s mode definitions. This is the
inventory taken while starting it, so the next session does not redo
it. `schemacs/progmodes/cc-mode.scm` already carries the whole change
machinery; what is missing is everything after `c-after-change` plus
the mode setup earlier in the file.

## Already available (checked, not guessed)

- `substitute-key-definition`/`-key` - `subr.scm`, ported for
  `tty-menu-navigation-map`, but the tree's signature takes all five
  arguments (`prefix` a vector, `(vector)` at top). Pass commands as
  their *procedures*: the port's `eq?` compares values.
- `map-keymap`, `set-keymap-parent`, `make-sparse-keymap`,
  `define-key`, `kbd`; `easy-menu-define` (`core/easymenu.scm`);
  `run-mode-hooks`; `c-initialize-builtin-style` and
  `c-make-styles-buffer-local` (`cc-styles.scm`);
  `*c-require-final-newline*` and `*mode-require-final-newline*`;
  the `c-mode-menu` language constant; `font-lock-defaults`'s
  buffer-local slots; `*font-lock-fontify-region-function*`,
  `*font-lock-support-mode*` and `*font-lock-extend-region-functions*`
  as parameters.
- `auto-mode-alist` already maps `.c`/`.h`/`.cc`/... to
  `c-mode`/`c++-mode`/`c-or-c++-mode`; adding them to
  `files.scm`'s `%mode-autoloads` is the wiring step once the modes
  exist.

## Missing, and what each needs (named, not papered over)

- `c-set-keymap-parent` (`cc-defs.el:518`): in Emacs 31/32 it is a
  macro choosing the XEmacs or Emacs arm; here it is a one-line
  procedure over `set-keymap-parent`, to add to `cc-defs.scm`.
- **file-style machinery** (`c-count-cfss`, `c-before-hack-hook`,
  `c-remove-any-local-eval-or-mode-variables`,
  `c-postprocess-file-styles`): waits on `hack-local-variables`,
  `file-local-variables-alist` and `before-hack-local-variables-hook`,
  none ported. Emacs also installs one of these on a hook at load
  (`cc-mode.el:983`); with no `hack-local-variables` there is nothing
  to hang it on, so this is a named gap of the mode tranche.
- **abbrevs** (`c-define-abbrev-table`, `c-populate-abbrev-table`,
  `abbrev-mode` in every mode body): `abbrev.el` is not ported (the
  electric pass already carries this as a gap).
- **`cc-imenu-init` / `flymake-cc`** in the mode bodies: imenu and
  flymake are not ported; the calls are named gaps, not stubs that
  pretend.
- **electric-indent-mode / electric-pair-mode connections**
  (`c-initialize-cc-mode`'s hooks, `c-electric-indent-mode-hook`,
  `c-electric-indent-local-mode-hook`,
  `c-electric-pair-inhibit-predicate`): neither mode is ported; the
  functions can be carried for shape but nothing calls them.
- **`post-text-conversion-hook`** (`c-initialize-cc-mode`): not
  ported (the function `c-post-text-conversion` is).
- **`boundp`/`fboundp` introspection**: cc-mode.el asks about
  `electric-pair-inhibit-predicate`, `yank-handled-properties`,
  `text-property-default-nonsticky`, `parse-sexp-lookup-properties`,
  `normal-erase-is-backspace`, `electric-indent-inhibit`, ...; the
  tree has no general `boundp` for library variables, so each is
  spelled as the fact it is (present/absent) with a comment, the way
  `cc-fonts.scm`'s `c-valid-offset` stands in for `functionp`.
- **A buffer-local `font-lock-fontify-region-function`**: Emacs's
  `c-font-lock-init` sets it per buffer; this tree's font-lock reads
  the *parameter*. Decide whether to give font-lock a buffer-local
  slot (truest) or set the parameter (leaks across buffers) before
  porting `c-font-lock-fontify-region`.
- `c-post-command` wants a *local* `post-command-hook` entry; the
  tree's hooks are global parameters. Either give hook lists a
  buffer-local form or guard the global entry on
  `*c-buffer-is-cc-mode*` - a decision, not a mechanical port.

## Scope order when taken up

1. C and C++ first (`c-mode`, `c++-mode`, `c-or-c++-mode`, their
   syntax tables, maps and menus), with `c-basic-common-init`/
   `c-common-init`/`c-font-lock-init` carrying the gaps above; the
   milestone is `.c`/`.h` opening with the syntax table and faces
   compared to Emacs (a face-run differential like
   `tools/cc-cgbs-diff/`).
2. objc/java/idl/pike/awk next - mechanical once the machinery works
   (their tables/menus are in cc-langs already); awk-mode's map wants
   the `c-awk-*` commands (`cc-awk.el`), which are not ported.
3. `c-buffer-is-cc-mode` stays a parameter set by the mode init (the
   documented stand-in); `c-leave-cc-mode-mode` on
   `change-major-mode-hook` is what clears it.

# Handoff — cc-mode menus, implicit int, and the keymap list (2026-11-26)

Three cc-mode gaps closed, plus a shared-primitive bug the first exposed.
DEPARTURES.md's section of this date has the C and the measured tables;
the things the next session needs:

* **`c-mode-menu` is carried** (`cc-langs.scm`, replacing the "not
  carried" note) with the two `easy-menu-define` calls in `cc-mode.scm`
  (C after its mode definition, C++ before its own, Emacs's order). The
  menu is less the items whose commands do not exist here:
  "Macro Expand Region" (`c-macro-expand`, a cpp subprocess), the Style
  submenu's two guess entries (`cc-guess.el`) and the "Subword mode"
  toggle (`cc-subword.el`). `:selected` holds the *accessor call*
  (`(c-syntactic-indentation)`), not the variable symbol, because the
  variables are accessors here. A command that Emacs writes as a *form*
  ("Uncomment Region", "Show Current Style Name") is evaluated in
  cc-mode's module, so its names must be imported there - `message`,
  `region-beginning`, `region-end` were added. Verified live on a Gtk
  editor: comment/uncomment on a region, the syntactic-indentation
  toggle, and the style message.
* **`c-forward-type`'s C implicit-int branch** (`cc-engine.scm`, the
  `register count;` case) had a stale signalling stub where Emacs calls
  `c-forward-declarator`; it is the C's expression now, six rows
  Emacs-measured in `cc-engine-test.scm`.
* **`lookup-key` over a keymap *list* was a first-match search.**
  `key-binding` passes `current-active-maps`, and Emacs's
  `access_keymap_1` accumulates the *prefixes* found in every map
  (`keymap.c:416-420`). `%maps-event-binding` did not, so a mode map
  whose menu bound `[menu-bar MODE]` hid the global `[menu-bar file]` -
  `(key-binding [menu-bar file])` was nil in a C buffer and **F10 opened
  no menu**. It now delegates to `access-keymap`'s list walk.
  `subr-test.scm` pins both measured answers; `tools/pty-check.py`'s
  `c-menu` is the end-to-end one (bar row has `C`; F10 + three rights
  drops the C menu down).

A correction worth carrying: **`message` formats with Emacs's `%`
conversions** (`styled_format`), not Guile's `~a`; a stale note misled
the first version of the style-name item into printing its format
literally.

State: cc-mode-test 136, cc-engine-test 635, subr-test 115; all 104
suites pass and the full pty battery was run on the settled tree. The
remaining cc-mode list is unchanged: the other five modes (objc, java,
idl, pike, awk - mechanical, with `c-beginning-of-objc-method-header`
still a stub and `cc-awk.el` unported), java's modifier-keyword
fontification bug, the fill differential's known point-handling cases,
and the small not-carried items named in cc-mode.scm's header.

# A Gtk click's menu/tool-bar rebuild (2026-11-26)

The ~4 s click latency Chris reported was both bars being rebuilt on the
redisplay that a click triggers, with each guile-gi call costing
milliseconds (76 % of the profile in GOOPS `class-precedence-list`).
Measured: the menu array differed in exactly two `enabled` booleans (the
Replace items, when the window switched to a read-only buffer), and the
tool bar's did the same. Both bars now patch enable-only changes in
place (`pgtk-update-menubar-toggles!`, `pgtk-toolbar-enable-slots-only?` +
`pgtk-update-toolbar-enables!`); anything else rebuilds, as Emacs's
`set_frame_menubar` always does and as our coarser-than-Emacs tool bar
does. Click processing measured **2.86 s -> 0.20-0.41 s**. The first,
faithful per-item tool-bar reuse loop SIGSEGV'd at Guile 3.0.11's
default optimization level (fine at -O1), so the two-tier shape above is
what ships; DEPARTURES.md has the numbers and the named departures.
`pgtk-test.scm` gained `schemacs_pgtk_bar_patch`; the live checks that
matter (widget `sensitive` flipping 0->1->0, a non-boolean change
answering "rebuild") were run against a real Gtk display.
