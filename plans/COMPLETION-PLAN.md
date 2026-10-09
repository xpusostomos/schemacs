# Completion from the minibuffer

Written 2026-09-28, companion to FACES-PLAN.txt, LAYOUT-PLAN.txt,
NCURSES-PLAN.txt and MG-PLAN.txt.

## Context

There is completion here already, and it is real: `read-file-name` prompts
with `default-directory` in the prompt, TAB completes as far as the text
can be completed, and `?` lists the candidates. What it is not is Emacs's.

`minibuffer.sld` holds `try-completion` and `all-completions` over a
completion table, `minibuffer-complete` on TAB, and
`minibuffer-completion-help`; `files.sld` has `file-name-completion-table`
and parameterizes the table around `read-from-minibuffer`. Three
simplifications were made, each because the thing Emacs uses was not here,
and each of them is now the thing to undo:

  * **The table is a procedure of one argument.** Emacs's may be a list, an
    alist, an obarray, a hash table, or a function - and the *function*
    form takes three arguments, `(STRING PREDICATE ACTION)`, because the
    caller tells the table which of the three questions it is asking.
  * **There is one style, and it is `basic`.** Emacs tries a *list* of
    styles in turn and uses the first that finds anything.
  * **The candidates go in the echo area**, as one long line. Emacs opens
    a `*Completions*` window.

That last one comes with a comment that has gone stale, which is worth
quoting because it records the reasoning that no longer holds:

    Emacs lists candidates in a *Completions* window; this editor has
    one window and no buffer list yet, so they are shown in the echo
    area instead.

Both halves of that are now false: `display-buffer` and the window list
arrived with the buffer-list work, and the buffer list with `buffer.sld`.
`window.sld` even says the split it can make "is the shape the completions
window needs". So the window can be built now.

## What Emacs's completion is

Seven layers, and the interesting thing about them is how little of the
work is in the minibuffer itself.

1. **The table** (`minibuf.c`: `Ftry_completion`, `Fall_completions`,
   `Ftest_completion`). The three questions, and the dispatch on what the
   table *is*: a list or alist (an element's car is the candidate), an
   obarray (symbol names), a hash table (keys that are strings or
   symbols), or a function - called with `(STRING PREDICATE ACTION)`, where
   ACTION is `t` for `test-completion`, nil for `try-completion`, and a
   function for `all-completions`. Plus a PREDICATE argument to each, and
   `completion-ignore-case`.

2. **The styles** (`minibuffer.el`: `completion-styles`,
   `completion-styles-alist`, `completion-all-completions`). A list tried
   in order until one finds something: `basic` (prefix), `substring`,
   `flex`, `initials`, `emacs22`. `completion-all-completions` also leaves
   a `base-size` in the last cdr, which is how the caller learns where the
   completion begins - that is what in-buffer completion is built on.

3. **`completing-read`.** Binds the table and the predicate, handles
   `require-match`, the default value and `minibuffer-completion-confirm`,
   and answers with the chosen string. `read-file-name` is three hundred
   lines *on top of* it, not the other way round.

4. **The RET family.** `minibuffer-complete-and-exit`: with
   `require-match`, RET on an exact match exits, and otherwise completes
   and says why it did not - "Sole completion", "Complete, but not
   unique", or "Confirm". Plus SPC `minibuffer-complete-word` and `?`
   `minibuffer-completion-help`.

5. **The `*Completions*` buffer** (`minibuf.c`'s
   `display-completion-list`, `simple.el`'s `completion-list-mode`): the
   candidates one per line, in a buffer with its own keymap - RET chooses,
   `n` and `p` move, `q` quits - shown in a window **without disturbing
   the minibuffer**. That last part is the whole difficulty: the minibuffer
   is being read by a recursive edit, and showing a window there must not
   take point out of the prompt. Emacs does it with
   `with-display-message`, `temp-buffer-show-function` and
   `minibuffer-hide-completions`.

6. **The faces** - `completions-common-part` on the part of a candidate
   that matched and `completions-first-difference` on the part that
   differs, so the list says *why* each candidate is there.

7. **`completion-in-region` / `completion-at-point`** - the same
   machinery completing in a buffer rather than the minibuffer, driven by
   `completion-at-point-functions`.

## Step A is done (2026-09-28)

**`editor/minibuf.sld`** (from `minibuf.c`) — `try-completion`,
`all-completions` and `test-completion`, with Emacs's argument lists and
names, and the dispatch onto the three table forms this project has: a
list or alist, a hash table, and a function (which is called with
`(STRING PREDICATE ACTION)`, not one argument - the old one-argument table
form is gone). 13 tests in `minibuf-tests.scm`.

`minibuffer.sld` no longer defines them; it imports them, as
`minibuffer.el` uses `minibuf.c`'s, and `try-completion`/`all-completions`
are no longer *exported* from it - a caller wants them from `minibuf`.

Three findings from translating the C rather than paraphrasing it:

- **`try-completion` is not "collect the matches, then take the common
  prefix".** It is a running best-match that *shrinks*, with an early exit
  once the match has come down to the length of the input and there is
  more than one candidate. And it answers `#t` only when the candidate
  set has exactly **one** member and it is the input - so
  `(try-completion "foo" '("foo" "foobar"))` is `"foo"`, not `#t`.
- **Every candidate is gated by the C's "Is this element a possible
  completion?" test** - at least as long as the input, and starting with
  it - before anything else is done with it. I left that out at first, and
  the symptom was *not* obvious: an unmatched candidate still took part in
  the shrink, so a completion with no match at all answered the empty
  string instead of `nil`.
- **`test-completion` compares the whole candidate**, where
  `all-completions` compares only as far as the input. A candidate that
  merely starts with the input is a completion *of* it, not the same as
  it - and that difference is exactly what RET asks about.

## Step B is done (2026-09-28)

The styles are in `minibuffer.sld` (where `minibuffer.el` keeps them): the
`*completion-styles*` list, `completion-styles-alist`,
`completion--nth-completion` and the two entry points
`completion-try-completion` / `completion-all-completions`, plus
`completion-boundaries`. 12 tests in `minibuffer-tests.scm`.

Two styles: **`basic`** feels like an old friend now, and **`substring`**
is what people notice missing. `minibuffer-complete` and
`minibuffer-completion-help` now go through the styles rather than
straight to `try-completion`, so both are actually reachable.

Three things worth knowing:

- **The answer to `completion-all-completions` is a *dotted list*** -
  `("foo" "food" . 0)` - because Emacs puts the *base size* in the last
  cdr, and that is how a caller learns how much of what was typed the
  completion replaces. `(cdr (last ANSWER))` is how Emacs reads it back.
  It is the kind of contract that looks like corruption until you know.
- **`completion-try-completion` answers a *pair*, `(NEWSTRING .
  NEWPOINT)`**, not a string - because a style may need point somewhere
  other than the end of the new text. `#t` still means "already the only
  completion" and `#f` "nothing".
- **A substring match is not a prefix**, so completing gives the *match*:
  completing "oo" against `("foo")` answers "foo" and point 3, where
  prefix completion answers nothing at all. That is the visible
  difference between the two styles, and the reason a list of them is
  worth having.

**What is deferred, and named in the library**: Emacs routes `basic`,
`substring`, `partial-completion` and `flex` through one **PCM pattern
engine** (a glob matcher over `*foo*bar*` patterns). `substring` here is
written directly - "the candidates the string appears in anywhere" - which
is what the style *means*, and is what the engine would be built on. So
the behaviour is right without the shared route. `partial-completion`,
`flex` and `initials` are not here; Emacs's default `completion-styles` is
`(basic partial-completion emacs22)`, and this library's default is
`(basic substring)` because those are the two it has.

## Steps C and D are done (2026-09-28)

`completing-read` and the RET family, in `minibuffer.sld` (where
`minibuffer.el` keeps them):

- `completing-read` — PROMPT, COLLECTION, and the optional PREDICATE,
  REQUIRE-MATCH, INITIAL-INPUT, HISTORY and DEF. It binds the table, the
  predicate and `minibuffer-completion-confirm`, picks
  `minibuffer-local-must-match-map` or `minibuffer-local-completion-map`
  by REQUIRE-MATCH, and calls `read-from-minibuffer`. `read-file-name` is
  now the thin layer over it that Emacs's is, instead of the hand-rolled
  one it was.
- `minibuffer--bitset` and `completion--do-completion` — the three bits
  (M modified, C completions, E exact) and the completion that produces
  them, with Emacs's two messages.
- `minibuffer-complete-and-exit` (RET in the must-match map),
  `minibuffer-complete-word` (SPC), and `minibuffer-completion-help` as a
  *command*, since `?` is bound to it.
- `minibuffer-local-must-match-map`, whose parent is the completion map.

4 more tests in `ncurses-editor-tests.scm` cover the keymaps, the bitset,
and a completion driven end to end.

Three things this cost, all worth writing down:

- **The completion keymaps are built at load time and name commands**, so
  they must be defined *after* the commands they bind - which is why
  Emacs has them at the end of `minibuffer.el` too. Placing them next to
  `minibuffer-complete` gives "unbound variable" at load.
- **A command is a record here, not a function**, so calling one is
  `(run-command C)`. `minibuffer-completion-help` was a plain function
  until it became a command for `?`'s sake, and the three places that
  called it had to change with it - the same trap `list-buffers` had.
- **`new-command` is `(NAME PROC API DOCSTR)`** - four arguments, and the
  API lambda is required. Converting a plain function into a command
  means adding one, and forgetting it fails at *load* with "wrong number
  of arguments", which is at least a clear error.

## Steps E and F are done (2026-09-28)

The completions window and the faces on it, and this is the first place a
*face on buffer text* reaches the screen - the gap FACES-PLAN.txt recorded
at the end of step D is closed by it.

- `display-completion-list` fills the `*Completions*` buffer with the
  candidates, one per line, and puts `completions-common-part` on the part
  the pattern matched and `completions-first-difference` on the first
  character past it.
- `completion-list-mode-map` and `choose-completion` - RET puts the
  candidate on the line into the minibuffer that is still being read, `q`
  takes the window away.
- `minibuffer-completion-help` now shows that buffer in a window with
  `display-buffer`, and no longer writes one long line into the echo area.
  The stale comment it carried - "this editor has one window and no buffer
  list yet" - is gone with it.
- The two faces are Emacs's own, converted from `minibuffer.el`.

The pty battery gained a `completions` check, and it asserts the thing that
matters rather than the obvious one: that the window opens **and that what
was typed is still in the prompt**, because showing a window while the
minibuffer is being read must not take point out of it. That is why it is
`display-buffer` and not `pop-to-buffer`.

Three things this turned up:

- **`file-name-completion-table` had to become a *function* table.** It
  took one argument; Emacs's `read-file-name-internal` takes three,
  `(STRING PREDICATE ACTION)`, because which names are candidates depends
  on what has been typed and the caller says which question it is asking.
  The old one-argument form is gone from the whole project.
- **`quit-window` was in the wrong library.** Emacs has it in `window.el`;
  ours was in `buff-menu.sld`, which only got away with it while nothing
  else needed it. The completions keymap needs `q`, so it moved.
- **The mode line shows `*Completions`, not `*Completions*`.** The format
  is `%12b` and a thirteen-character name is truncated to twelve. That is
  probably what Emacs does with a positive field width - but it is worth
  one check against real Emacs, and it is not something step E should
  quietly decide either way.

## Two bugs in the first cut of C and D (2026-09-28)

Both reported from the editor, both mine, and both worth keeping:

**1. `(length ...)` on a string.** `minibuffer-complete` computed how much
to insert as `(substring new (length (common-prefix ...)))` - and
`common-prefix` returns a *string*, where `length` wants a list. The
symptom was `Wrong type argument in position 1: "LI"` on TAB, and it only
appeared when the text *matched* something: with no match the branch is
never reached, so `z TAB` said "No match" and looked fine. `string-length`
was meant.

**2. `default-directory` during a minibuffer read.** The minibuffer is read
by a recursive edit, and `current-buffer` is then the *minibuffer* - so
`default-directory` resolved against it, found nothing, and fell back to
the *process's* directory. Completing a file name in `/tmp/ctest` offered
the editor's own `build.scm` for `b`, and found no `alpha.txt` at all
because it was looking in the wrong directory.

The fix is Emacs's: the minibuffer *inherits* the asking buffer's
`default-directory` when it is set up. It has to be copied at setup and
not read later, for the reason above - and that is the general shape of
the trap, since anything else reading `current-buffer` from inside a
minibuffer command has it too.

The pty `completions` check now drives TAB as well as `?`, which is what
would have caught the first one: `?` never reaches the completion-inserted
branch.

## The layers

Each named for the Emacs file whose role it fills, per LAYOUT-PLAN.txt.
Note that this splits across two files the way Emacs does - `minibuf.c` is
the three functions and the dispatch, `minibuffer.el` is everything built
on them.

### A. The table - `minibuf.c` → `editor/minibuf.sld` (NEW)

**Done — see the section above.**

`try-completion`, `all-completions` and `test-completion`; the dispatch on
list / alist / hash table / function; the PREDICATE argument; the function
form's `(STRING PREDICATE ACTION)`. `completion-ignore-case`.

Obarrays are not here: an obarray is a Lisp object this project has no
analogue of, so that one form waits for the elisp layer, which is where a
Lisp symbol table will live.

### B. The styles - `minibuffer.el` → `editor/minibuffer.sld`

**Done — see the section above.**

`completion-styles`, `completion-styles-alist`, `completion-all-completions`
with its `base-size`, and at least `basic` and `substring`. `substring` is
the one whose absence is noticed: typing a fragment from the middle of a
long file name completes in Emacs and not here.

### C. `completing-read` - `minibuffer.el` → `editor/minibuffer.sld`

**Done.**

The function all the others are written against, with `require-match`, the
default value and the predicate. `read-file-name` then becomes the layer
over it that Emacs's is, instead of the hand-rolled one it is.

### D. The RET family - `minibuffer.el` → `editor/minibuffer.sld`

**Done.**

`minibuffer-complete-and-exit`, `minibuffer-complete-word`, and
`minibuffer-completion-confirm`, with Emacs's three messages.

### E. The `*Completions*` buffer - `display-completion-list` + `completion-list-mode`

**Done — see the section above.**

From `minibuf.c` and `simple.el`. The buffer, `completion-list-mode` and
its keymap, and `minibuffer-completion-help` filling it and showing it in
a window without disturbing the minibuffer. This is where the pty battery
earns its keep: the interaction between a window being shown and a
minibuffer being read is exactly the class of bug the unit suites cannot
see.

### F. The faces - `completions-common-part` / `completions-first-difference`

**Done — see the section above.**

From `faces.el`, and the first real user of faces on *buffer text*: the
run walk in `xdisp.sld` is exercised by nothing in the editor today, and
this is the smallest honest thing that puts a face on text. See the end of
FACES-PLAN.txt, where that gap is recorded.

### G. `completion-in-region` / `completion-at-point` - separate, later

Completing in a buffer rather than the minibuffer. Needs the region and
markers, and is its own plan.

## Order

1. **A** - the table layer, entirely in a new `minibuf.sld`, testable
   headlessly and with nothing else depending on it changing.
2. **B** - the styles, with `basic` and `substring`.
3. **C** and **D** - `completing-read` and the RET family, which is where
   `read-file-name` gets simpler rather than more complex.
4. **E** and **F** together - the window and the faces, because the faces
   are what make the list look like Emacs's.

## Not in this plan

**Obarrays**, as above. **`completion-in-region`**, as above. **The
completion UI added in Emacs 30** (`completion-auto-deselect`,
`completion-eager-update`, `completion-lazy-hilit`, the auto-updating list
in `*Completions*`) - Emacs 31's `minibuffer-completion-help` is built
around it, and it is a large piece of behaviour to add on top of a
`*Completions*` buffer that does not exist yet. The plan is to reach
Emacs's *older*, simpler behaviour first and say so, rather than to
half-build the new one.

## Verification

The habits that have been finding the real bugs here:

- `tools/syntax-check.scm` after every scripted edit to a `.sld`, **and**
  `guile --no-auto-compile -L . -c '(import ...)'` - the reader can
  pass a file the expander rejects, which has cost time twice now.
- Unit tests for the table layer: the four forms, the predicate, the
  function form's three arguments, `test-completion` disagreeing with
  `try-completion` (it is the one that says whether the input is *valid*,
  where `try-completion` says what it could become), and case folding.
- A pty check for the `*Completions*` window, since the unit suites never
  render and never open a second window.

## Step H: the things a user notices (2026-09-28)

Chris used the completion and listed six ways it differs from GNU Emacs,
plus a seventh while the work was in progress. All seven are fixed. They
are worth recording because none of them is visible to a unit test that
calls a function and looks at what comes back: each is about the echo
area, the second window, or a key.

**1. Leaving the minibuffer takes the completions window with it.**
Emacs records the window configuration on the way into a minibuffer and
restores it on the way out (`src/minibuf.c:700`), so the `*Completions*'
window goes whether you left with RET or with C-g, and so does a
completion that succeeded. The default of `read-minibuffer-restore-windows'
is `t`, so that is the route Emacs takes; `minibuffer-hide-completions'
(`minibuffer.el:3065`, on `minibuffer-exit-hook') is the *other* route,
for when it is nil. This project has no window configurations, so it
takes the second route for every exit - which is equivalent for the
window this is about, and is written down as the knowing deviation it is
in `minibuffer-restore-windows'' own docstring.

**2. And so does a successful completion** - the same hook, which is why
it is one fix rather than two.

**3. Messages are enclosed in `[...]` with a space in front.**
`minibuffer-message` (`minibuffer.el:813`) writes `" [" MESSAGE "]"`,
which is Emacs's mark that the editor is talking rather than that the
answer says this. "No match", "Sole completion", "Complete, but not
unique" and "Confirm" all go through it now (they are `completion--message'
calls in Emacs, gated on `completion-show-inline-help').

**4. Messages time out.** `minibuffer-message-timeout` is 2 seconds, set
in `keyboard.c:14310`, and Emacs arms a timer for it and *also* clears on
the next input event. There are no timers here, so the frame now carries
the time the message should come down at, and the command loop's `getch'
is given a 100 ms timeout while one is pending - armed and disarmed, so
that a blocking read is still what notices end of input. The first
attempt at this was wrong in a way worth keeping: `guile-ncurses`'s
`getch' answers `#f' for a timed-out read, *not* the `ERR' integer the
old code tested for - so the test for end of input had never fired.

**5. `M-<up>' and `M-<down>' move through the candidates, and RET takes
the one moved to.** `minibuffer-next-completion' / `-previous-completion'
(`minibuffer.el:5356`) move point in the `*Completions*' buffer while
point stays in the minibuffer, and `minibuffer-completion-exit' - what
RET is bound to in a completion map - takes a selected candidate before
leaving. Two things had to happen first:

  * **The arrow keys had to become keys of their own.** They were being
    folded onto the control keys that move the same way (KEY_UP to
    `C-p'), which is what a terminal does when it has no arrow keys, and
    the cost was that `M-<up>' - a key in Emacs's completion map -
    arrived as M-C-p and could not be bound. They are `<up>', `<down>',
    `<left>', `<right>', `<home>', `<end>' and `<delete>' now, bound in
    the default map to the same commands the control keys run, exactly as
    `bindings.el' binds them.
  * **The selection had to be visible.** Emacs puts a `cursor-face'
    property on the candidate and lets the display decide; this editor's
    display reads `face', so the selected line is given
    `completions-highlight' (which `:inherit's `highlight', as Emacs's
    does) - and *rewritten* rather than merely added to, so that taking
    the selection off a line puts back the `completions-common-part'
    highlighting it had.

**6. `M-6' is not an undefined key.** It is `digit-argument'
(`simple.el:5596'), which `bindings.el' binds to M-0..M-9, C-0..C-9 and
C-M-0..C-M-9 - with `negative-argument' on the three minus keys. The
prefix state gained a sign for it, since Emacs carries the sign in the
*value* (`prefix-arg' may be the symbol `-') and a string of digits
cannot spell it.

**7. SPC inserts a space in a file name.** This is
`minibuffer-local-filename-completion-map', whose entire content is
`"SPC" nil' - a nil binding in a composed keymap overriding its parent,
which is what `make-composed-keymap' documents. `read-file-name' layers
it by binding `minibuffer-completing-file-name', and `completing-read'
composes the map. A deviation, and an honest one: this keymap machinery's
layers fall through on a nil action rather than letting it shadow, so the
map says `SPC' is `self-insert-command' - the command the nil binding
comes to - instead of saying nothing.

### Three bugs found on the way

  * **`minibuffer-set-contents!' prepended instead of replacing.** It
    deleted from the cursor and then moved the cursor to the beginning,
    and the engine deletes *forward* from the cursor - so the deletion,
    at the end of the text, took nothing, and choosing a completion read
    "scratch.mdsc". Stepping through the history was wrong the same way.
  * **`read-file-name' answered with a relative name.** Emacs puts the
    directory *in* the minibuffer, so its answer is absolute; this
    editor's prompt carries the directory beside the buffer, so a bare
    name meant nothing to anything that opens a file - `C-x C-f notes.txt'
    only worked when the editor's own directory happened to be the right
    one. The answer goes through a new `expand-file-name' now, whose
    behaviour was checked against Emacs's for `.`, `..`, `//`, an
    absolute name, and the empty name.
  * **`M-RET' was spelled wrong in the keymap** - `(meta (ctrl #\m))'
    rather than `(meta ctrl #\m)' - and the keymap read it as a chord
    ending in `C-m', so it *shadowed* RET. The symptom was RET in a
    `C-x C-f' prompt saying "No completion here".

### Tests

Seven more unit tests in `ncurses-editor-tests.scm` (the enclosing, the
timeout, `completion-show-inline-help', the replacement, the file-name
layer, `expand-file-name') and a new `completion-ui' check in the pty
battery, which drives all seven of the reported divergences. The check
that M-<down> moves the selection asserts that the two RETs land on
*different* files rather than on a particular one, because the candidates
come out in `readdir' order - which is a divergence of its own, worth
noting: Emacs sorts its completions (`completions-sort'), and this does
not.

## Step I: four more from Chris's second pass (2026-09-28)

He drove the editor again and reported four things, and then a fifth
while they were being fixed. All are done.

**1. `M-<up>`/`M-<down>` came back as "unhandled event: 532".**
That is ncurses telling us what the key was, in a vocabulary the editor
did not read: a key carrying a *modifier* is reported as an **extended
keycode** - a number above `KEY_MAX` - and ncurses names them from
terminfo. `(keyname 532)` answers `"kDN3"`: the `DN` is the down key and
the `3` is Meta, which is xterm's `CSI 1 ; 3 B` and exactly how
GNU Emacs reads the same sequence in `term/xterm.el` (`\e[1;3A` is
`[M-up]`, `\e[1;3B` is `[M-down]`). So the decoder takes the name apart -
key and modifier digit - and builds the key path; the digits are
`2 = Shift, 3 = Meta, 4 = Shift+Meta, 5 = Ctrl, 6 = Shift+Ctrl,
7 = Ctrl+Meta, 8 = Shift+Ctrl+Meta`, the same numbering.

Two notes. `keyname` has to be *asked* at key time, because the terminfo
has to be loaded; and 2, 4, 6 and 8 all carry Shift, which this editor's
keymap machinery has no modifier for, so those stay unhandled.

The first attempt at this was wrong in a way worth recording: it decoded
`keyname` *before* `initscr`, where every name comes back "(unknown)".

**2. `M-6` showed `6-` in the minibuffer, where Emacs shows nothing.**
Emacs echoes the keys typed so far - and the prefix description with them
- only **after `echo-keystrokes` of idling** (`read_char`'s `sit_for`),
so typing straight on says nothing at all; and only **when no minibuffer
is active** (`if (minibuf_level == 0 ...)`, `keyboard.c:2857`), which is
Chris's point that it "doesn't make sense to show it in the minibuffer".

Both are now what happens, and the description is Emacs's
`universal-argument--description` - which always begins `C-u`, whatever
key began the argument, so `M-6` paused over reads `C-u 6`. The waiting
rides on the idle tick the message timeout already needed.

**3. `R<TAB>` then `<TAB>` said "[Complete, but not unique]" where Emacs
says "[Sole completion]".** Two bugs, one behind the other:

  * `minibuffer-complete` had a *copy* of the messages of its own, and
    answered `try-completion''s `t' with the wrong one. Emacs's
    `minibuffer-complete` is three lines that hand the work to
    `completion-in-region` → `completion--do-completion`, and this is the
    same now: one place says what happened, so two cannot disagree.
  * The *file-name table* answered the third question wrong. A function
    completion table is asked three things, and `test-completion` is the
    third - "is what is typed already valid?" - which
    `file-name-completion-table` answered with `all-completions`, a *list*
    of names. A non-empty list is true whatever the name was, so every
    name typed looked like a valid completion. GNU Emacs's
    `completion-file-name-table` answers it with `file-exists-p`. (So
    `C-x C-f` had never once said "no such completion".)

  The order of `completion--do-completion`'s cases was wrong too, and it
  is the order that matters: **a completion that happened says nothing**
  (and takes a stale candidates window away); only a TAB that completed
  nothing says anything - "Next char not unique" or the candidates, or
  "Complete, but not unique" when what is there is a valid completion
  among others. So one TAB is silent and a second shows the list, which
  is how Emacs behaves and did not here.

**4. `C-x C-f` on a name that does not exist said "error loading".**
It is how a file is *created*. `find-file` read the file unconditionally;
it now follows `find-file-noselect` and `after-find-file`: a name that is
not there gives an empty buffer with `buffer-file-name` set to it,
`default-directory` its directory, and "(New file)" in the echo area.

Two more things fell out of that. `file-write-protected?` asked about the
file and found no permission bits, so a *new* file was visited read-only -
`file-writable-p` is "can be written or **created**", and asks the
directory when the file itself answers ENOENT. And `find-file` on a file
already in a buffer re-read it *into* that buffer, appending a second copy
of the file to the first; Emacs's `find-file-noselect` answers with the
buffer it already has.

**5. (During the work.) The completions buffer carries Emacs's two help
lines and its heading.** Real Emacs shows

    Type M-RET on a completion to select it.
    Type M-<down> or M-<up> to move point between completions.

    2 possible completions:
    apricot.txt
    apple.txt

- `completion-setup-function` on `completion-setup-hook` for the two
lines, `completions-header-format` (default `"%s possible completions:\n"`,
in the `shadow` face) for the heading, both of which this editor lacked.
`completion-setup-function` is simple.el's in Emacs and cannot be here,
because it fills the `*Completions*` buffer and simple is imported *by*
this library; it is written down as the knowing deviation it is.

The two lines are why a candidate is now marked with a `completion--string`
text property rather than being "the line point is on" - Emacs's own
marker, and what keeps the heading and the help from looking selectable.
Point is left where Emacs leaves it, on the heading line, so the first
`M-<down>` reaches the first candidate; RET without moving leaves with what
was typed, as it does in Emacs.

**And it is written in a different order than Emacs writes it** - the help
first, then the heading and the candidates, where Emacs writes the
candidates and then inserts the help at `point-min`. That is a workaround
for a real bug, and the finished buffer is identical either way. See the
note on `offset_intervals` in AGENTS.md.

## Step J: two more (2026-09-29)

**`C-x C-f` did not prompt with the directory in a buffer started on a
file.** It did in one that had not been. `find-file` used the name it was
given as it stood, and the directory part of a *bare* name is the empty
string: started with `emacs foo`, the buffer's `default-directory` was
`""`, which is true, so `(or ... (getcwd))` never fell through and the
prompt read "Find file: " and nothing else. GNU Emacs's
`find-file-noselect` expands the name before anything else -
`(setq filename (abbreviate-file-name (expand-file-name filename)))` -
and this does the same now, with `expand-file-name` already in the file.
The other half of that line, `abbreviate-file-name`, is not implemented:
nothing here has a home directory to shorten against.

**`default-directory` has a global default.** Making the above work
showed that it could not answer with no current buffer at all - which is
what a `find-file` from a script or a test has - because `(current-buffer)`
went on to the frame's selected window and there was no frame. Emacs's
`default-directory` is a variable *with* a global value (the process's
directory) that buffers make local; that is what it says now.

`tools/pty-check.py` gained a `default-directory` check: `C-x C-f` in a
buffer visiting a bare name must prompt with a directory, and one visiting
`tools/pty-check.py` must prompt with `tools/`.

## The insert-at-point-min bug, fixed (2026-09-29)

The completions help lines are inserted at `point-min`, into a buffer whose
text already carries properties, and that came apart - which is why this
plan recorded the help being written *first*, into an empty buffer, as a
knowing departure. The departure is gone: the bug is fixed, and the buffer
is now filled the way Emacs fills it.

**What it was.** `adjust_intervals_for_insertion` does two things:

  1. grow every interval above the insertion point (walking up to the
     root), and
  2. *then* work out what properties the new text gets, by merging the runs
     either side of it and splitting the interval if the merge says
     something different from what is there.

In the C those are sequential statements. In this port the merge - and the
split it can ask for - was **nested inside the growing walk**, so it ran
once per ancestor rather than once. At position 0 of a two-level tree the
merge ran twice, and the second time split the interval the first split
had already moved: the interval ended up with a negative length and a
position past the end of the buffer. Sometimes that raised on the spot;
sometimes it left a corrupt tree that came apart later, three frames away,
as "Wrong type argument in position 1 (expecting struct): #f".

**How it was found.** By printing `(interval-position i)` and
`(interval-length i)` from inside the branch that splits - the raise
surfaced far from its cause, and Guile's own backtrace was useless because
the record printer for `<text-editor-type>` throws while it is being
printed ("precondition failed"), masking the frames. Two things are worth
remembering: an instrumented *copy* of a function proves nothing unless
its parens are identical to the original's (twice mine were not, and the
"it works in the traced version" conclusion was worthless), and a tree
whose totals agree can still be wrong - the check that caught it in the
end compares the *runs* the tree reports, since positions are a cache and
only trustworthy along the path the last lookup walked.

**The tests.** `intervals-tests.scm` builds the two-level shape by hand
(the run at the front carries a property and is not the root, so the walk
has two steps) and asserts the runs after an insert at 0 -
`(0 5 ()) (5 15 (face shadow)) (15 25 ())`; with the bug they come out
`(0 5 ()) (5 10 ()) (10 15 ()) (15 15 (face shadow)) (15 25 ())`, with the
property stranded on a zero-length interval, which is exactly the kind of
wrongness that does not raise. The pty battery's `completions` and
`completion-ui` checks fail with the bug reverted, so the end-to-end
coverage is there too.
