# The mark, the region, and the kill ring

Written 2026-09-29, companion to COMPLETION-PLAN.txt, FACES-PLAN.txt,
LAYOUT-PLAN.txt and MG-PLAN.txt.

## Context

Chris asked for mark, regions, cut, copy, yank - and the kill ring. They
are one piece of work, because in Emacs they are one piece: the region is
what `kill-region' and `copy-region-as-kill' act on, and the mark is what
makes a region.

What is here now, and it is mg's rather than Emacs's:

  * **The kill ring is a single string** - `*kill-buffer*' in
    `simple.sld', with mg's CFKILL protocol: consecutive kills accumulate
    into it, a forward kill appending and a backward kill prepending. There
    is no ring, so there is no `yank-pop' (M-y) and no `kill-ring-max'.
  * **The mark is an engine fact with no user commands.** `buffer.c''s
    marker is there (`text-editor-mark', `set!text-editor-mark',
    `mark-marker'), and `exchange-point-and-mark' (C-x C-x) uses it - but
    nothing *sets* it. There is no C-SPC, no region, no `mark-active'.
  * **`region' exists as a face** (`faces.sld', converted with the others)
    and nothing draws it.
  * **No `transient-mark-mode', no `delete-selection-mode'.**

So `C-SPC', `M-w', `C-w', `M-y' and `C-x h' are all undefined keys today.

Worth saying why this is the right next step rather than a nice-to-have:
`completion-in-region' - step G of COMPLETION-PLAN.txt, deferred because
"it needs the region and markers" - needs exactly this. So does
`kill-region' inside a minibuffer, and so does every region command Emacs
has that we will want later (`indent-region', `comment-region',
`write-region', `shell-command-on-region').

## What Emacs's model is

**The mark.** A per-buffer *marker* - `BVAR (b, mark)`, which the engine
already has. Setting it also activates it and pushes the old one onto
`mark-ring' (`mark-ring-max' 16), which is what `C-u C-SPC' walks back
through.

**The region.** Two positions, `region-beginning' and `region-end', taken
from point and the mark in whichever order they lie, and only when the
mark is *active* - `use-region-p' is "active and non-empty", and
`region-active-p' is `(and transient-mark-mode mark-active)'. Commands
that act on the region check those, not the mark alone, which is why
`kill-region' with no active mark says "The mark is not set now, so there
is no region" rather than killing something arbitrary.

**Transient mark mode.** A global minor mode that makes the mark
*transient*: active until a command that is not a motion or a mark command
runs. Its default is a nice piece of Emacs trivia worth recording - it is
nil in C (`buffer.c' sets `Vtransient_mark_mode = Qnil') and nothing in
Lisp enables it either; what turns it on is `cus-start.el':

    (transient-mark-mode editing-basics boolean nil
                         :standard (not noninteractive))

- so it is **on in an interactive session and off under `--batch'**, which
is why `emacs --batch -Q' answers nil and a real session highlights the
region. Anything here that tests against `emacs --batch' has to remember
that.

**`delete-selection-mode' is a different thing and is off by default**
(measured on Emacs 31: `(and (boundp 'delete-selection-mode)
delete-selection-mode)' is nil in a session). It is what makes typed text
*replace* an active region; without it, typing with a region active
inserts, which is Emacs's behaviour out of the box.

**The kill ring.** `kill-ring' is a *list* of strings, newest first, and
`kill-ring-max' is 120 on Emacs 31. `kill-ring-yank-pointer' points
somewhere into it and is what M-y rotates. The three entry points:

  * `kill-new STRING &optional REPLACE' - push it on the front (dropping
    the oldest past `kill-ring-max') and set the yank pointer to the
    front; REPLACE overwrites the front instead, which is how a
    consecutive kill *extends* the last one;
  * `kill-append STRING BEFORE-P' - the consecutive-kill case:
    `(kill-new (concat string cur))', or prepending when BEFORE-P;
  * `current-kill N' - the Nth kill back from the yank pointer, moving the
    pointer; `(current-kill 0)' is "the latest kill".

`kill-region' (C-w) kills into the ring, appending when the last command
was also a kill and the text is contiguous; `kill-ring-save' /
`copy-region-as-kill' (M-w) is the same without deleting. `yank' (C-y)
inserts `(current-kill 0)' **and sets the mark at the start of what it
inserted** - which is what lets `yank-pop' (M-y) replace it: M-y deletes
back to that mark and inserts the previous kill, and is bound so that it
only works immediately after a yank.

mg's rule and Emacs's agree on the visible thing - consecutive kills join
- which is why `kill-line' and the word kills that already exist can keep
their behaviour while the storage underneath becomes Emacs's ring.

## The steps

### A. The mark and the region - DONE (2026-09-29)

Where each piece went, which is where Emacs declares it - this was got
wrong first time round and Chris caught it:

  * `mark-active', `transient-mark-mode' → **`editor/buffer.sld`**, because
    they are `buffer.c`'s variables (`DEFVAR_PER_BUFFER ("mark-active")`,
    `DEFVAR_LISP ("transient-mark-mode")`).
  * `mark-even-if-inactive` → **`editor/command.sld`**, because it is
    `callint.c`'s - the `interactive` machinery is what asks whether the
    region is wanted when the mark is inactive.
  * `region-beginning', `region-end', `region-limit' → **`editor/editfns.sld`**
    (NEW), because they are `editfns.c`'s.
  * `add-to-history' (and `nthcdr', which it needs) → **`editor/subr.sld`**
    (NEW), because they are `subr.el`'s.
  * `deactivate-mark` is `keyboard.c`'s variable, *written* from
    `insdel.c`'s `prepare_to_modify_buffer' and read by the command loop.
    A Scheme library cannot write another's variable, so the storage is an
    engine field (`text-editor-deactivate-mark' / `set!...') and
    `keyboard.sld` reads and clears it - the one place a C cross-file
    variable had to move.

Everything else is simple.el's and stayed in `simple.sld`: `mark',
`set-mark', `push-mark', `pop-mark', `push-mark-command',
`pop-to-mark-command', `set-mark-command', `mark-whole-buffer',
`activate-mark', `deactivate-mark', `use-region-p', `region-active-p',
the mark ring, and the hooks.

`add-to-history` also needed `nthcdr`, because Elisp's `(nthcdr 15 '(x))`
is nil where Scheme's `list-tail` is an error - the first of two such
sloppinesses that this one function ran into (`(car nil)` was the other).

### A2. What the C's `region_limit` does that is easy to get wrong

With Transient Mark mode on and no active mark, `region-beginning' signals
`mark-inactive' ("The mark is not active now") **whether or not a mark was
ever set** - that is the *first* test the C makes. "The mark is not set
now, so there is no region" is the *second*, and is reached only when the
mode is off or `mark-even-if-inactive' is set.

### A3. The old heading, kept for the list of functions

### A. The mark and the region - `editor/simple.sld` (simple.el)

`*mark-active*`, `*transient-mark-mode*` (on, as it is interactively),
`*mark-even-if-inactive*`, `activate-mark`, `deactivate-mark`,
`use-region-p`, `region-active-p`, `region-beginning`, `region-end`,
`set-mark-command` (C-SPC and C-@ - the same byte), `pop-mark` and
`*mark-ring*` with `C-u C-SPC`, `mark-whole-buffer` (C-x h), and
`push-mark`.

`deactivate-mark' has to be called by the *command loop*, not by the
commands: Emacs's `command_loop_1' runs it after a command unless that
command is one of `this-command-keys-shift-translated'/a motion/mark
command. That is what makes the highlight go away when you type. It goes
in `dispatch-action' beside the kill-flag rotation, which is the same idea
about the same place.

### B. The kill ring - DONE (2026-09-29)

`kill-ring` (a list), `kill-ring-yank-pointer` (a *tail* of it, as in
Emacs), `kill-ring-max` (120), `kill-new`, `kill-append`, `current-kill`,
and the commands over them: `kill-region` (C-w), `kill-ring-save` (M-w)
with `copy-region-as-kill` under it, `yank` (C-y) rebuilt on
`current-kill`, and `yank-pop` (M-y). `delete-region` went to
`editfns.sld`, which is `editfns.c`'s.

**mg's `*kill-buffer*` is gone**, and with it mg's CFKILL protocol. The
visible behaviour is the same - consecutive kills join - because the two
rules agree; what is new is that there is somewhere to rotate *to*, so
M-y exists. `kill-range` kept its name and its callers (`kill-line`, the
word kills) and is now a thin layer: `kill-append` on a run of kills,
`kill-new` to start one. `isearch.sld`'s `isearch-yank-kill` had used the
old buffer and is now Emacs's `(isearch-yank-string (current-kill 0))`.

The rule that makes kills join is worth knowing, because it is not where
it looks: Emacs's `kill-region` tests `(eq last-command 'kill-region)` and
then **sets `this-command` to `kill-region`** - so a command that kills
*renames itself*, and the next command sees a kill as the last one,
whatever key ran it. That is exactly what `*last-command-kill*` is, and it
is why a C-y *between* two kills breaks the run (a yank is not a kill),
which one of these tests had to be corrected to say.

### B2. Three things had to match Emacs exactly, and did not at first

  * **Which way `kill-append` goes.** Emacs's BEFORE-P is `(< end beg)`
    with BEG the mark and END point - true for a *backward* kill. The
    first version here passed `forward?` straight through, which is the
    same idea the other way up, so every kill was prepended; the tests
    caught it (`one two` came out `twoone`).
  * **`C-w` with an *empty* region.** Not an error: Emacs's interactive
    form asks for `(mark)` and `(point)`, gets the same position twice, and
    puts the **empty string** in the ring. Checked in `emacs --batch`
    rather than argued about, and now the same here. The "no region"
    error is for *no mark*, and with Transient Mark mode on an inactive
    mark says "The mark is not active now" instead - because `region_limit`
    tests that first.
  * **`C-u C-y` is not "yank four times".** This one reached further than
    the kill ring: our prefix argument was a *number*, so a bare `C-u`
    arrived as 4 and could not be told from `C-u 4`. Emacs's raw value for
    a bare `C-u` is the **list** `(4)` - `universal-argument` sets
    `prefix-arg` to `(list 4)` - and commands ask which it is: `yank` takes
    the latest kill for the list and the Nth for the number, and
    `set-mark-command` pops the mark ring only for `C-u C-u`, the list
    `(16)`. `pending-uarg` returns the list now, `uarg->integer` reads the
    number out of it (the C's `prefix-numeric-value`), and the two commands
    that care ask `pair?` as Emacs asks `consp`.

### B3. The old heading, kept for the list of functions

### B. The kill ring - `editor/simple.sld` (simple.el)

`*kill-ring*` (a list), `*kill-ring-max*` 120, `*kill-ring-yank-pointer*`,
`kill-new`, `kill-append`, `current-kill`, and then the commands over
them: `kill-region` (C-w), `kill-ring-save` / `copy-region-as-kill`
(M-w), `yank' rebuilt on `current-kill` (and setting the mark, which it
does not today), `yank-pop` (M-y), `kill-whole-line`? (no - that is
`kill-line''s business), and `delete-region`.

mg's `*kill-buffer*' goes away; `kill-range' keeps its signature and its
callers (`kill-line', `kill-word', `backward-kill-word') and becomes a
thin wrapper that decides append-vs-new and calls `kill-new'.
`*last-command-kill*` stays - it is how "was the last command a kill" is
asked, and Emacs asks the same question with `last-command'.

Also `*kill-do-not-save-duplicates*' (nil by default) - cheap, and it is
what stops C-w on the same text twice filling the ring.

### C. Drawing the region - `editor/xdisp.sld`

The active region is drawn with the `region' face. Emacs does it in
`face_at_buffer_position': the face the display uses is the `face'
property *merged with* the region face for a position inside the region.
That is exactly the seam this renderer already has - `line-face-runs` and
`face-at-buffer-position' are where the `face' property becomes an
attribute number - so the region goes in there, and no text property is
written or removed. (Emacs also has `highlight-nonselected-windows',
which is about which *windows* show it; one window here, so it does not
arise yet.)

### D. The command loop - `editor/keyboard.sld`

The `deactivate-mark' call from step A, and the rule for which commands
may keep the mark: a command that moves point *keeps* it only in
`transient-mark-mode''s sense (motion commands do not deactivate), which
is why Emacs asks `this-command' rather than the buffer.

### E. `delete-selection-mode' - `editor/delsel.sld` (delsel.el)

**Off by default**, as in Emacs, so it is last and may be skipped: the
mode, its `delete-selection' property table, and the `self-insert-command'
/ `yank' / `kill-region' hooks that make typed text replace the region.
The file name is `delsel.el''s, per the usual rule.

## Not in this plan

`interprogram-cut-function' / `interprogram-paste-function' - the system
clipboard. On a terminal that means OSC 52, which is a platform concern
for `(schemacs ui platform ncurses)' rather than an editor one, and worth
its own decision (not every terminal supports it, and it can be slow). It
is where "cut and paste between the editor and other programs" lives, so
it is worth doing - just not here.

Also not here: shift-selection (`shift-select-mode', which needs the shift
modifier in a key event - our keymap machinery has no shift), `yank-handler'
and the text-property transfer of a yank, and `kill-region''s
`kill-read-only-ok'.

## What it unblocks

  * `completion-in-region' and `completion-at-point' - COMPLETION-PLAN.txt
    step G, and the last piece of "completion from the minibuffer" that the
    plan still lists as missing besides sorting.
  * `kill-region' in a minibuffer, and `M-w' anywhere.
  * The region commands we will want next: `indent-region',
    `comment-region', `write-region', `shell-command-on-region',
    `delete-region', `upcase-region'.

## Verification

The habits that have been finding the real bugs here:

  * `tools/syntax-check.scm` after every scripted edit, **and**
    `guile --no-auto-compile -L . -c '(import ...)'` - the reader
    can pass a file the expander rejects.
  * Unit tests for the parts that are pure: the ring (push, max, append
    and prepend on consecutive kills, `current-kill''s rotation and its
    wrap, the yank pointer after each), the region (beginning/end in
    either order, `use-region-p' with and without an active mark, the
    errors when there is no mark), and the mark ring.
  * Unit tests for the region *face*: it is the renderer's run walk that
    has to merge it, and that is testable headlessly - the same way the
    `completions-common-part' runs are.
  * pty checks, because three of these are things only a screen shows:
    C-SPC then motion then C-w cuts the region and the highlight goes;
    M-w then C-y then M-y rotates; and the region highlight disappears
    after a command that is not a mark command. Each verified to fail
    with its fix reverted, as usual.

## Where step A's verification stands (2026-09-29)

Green: `tools/run-suites.py` (113 engine + 169 frontend), the pty battery
14/14, `build.scm`, the three name/import checks, and the new
`tools/check-exports.scm`.

One thing is **not** green and is not fixed: under `run-tests.scm` - the
old combined runner, which loads every suite into *one* process - two of
the new mark tests fail (the region-order test and the use-region-p test),
though they pass when the file is run alone. What the failure looks like:
C-SPC reaches the command, the echo area says "Mark activated", and yet
the mark, `mark-active` and the mark ring are all unchanged on the buffer
the test is looking at. It is order-dependent, so *something* another
suite leaves behind is being read by the command - and binding every
parameter `run-keys*` binds (including the prefix ones) did not fix it.
Two theories worth trying next: a buffer-local value left in the
`(schemacs weak)` store by the suite before (`buffer-tests.scm` is the one
directly before it, and it tests the store), or `current-buffer` resolving
to a different buffer *inside* the command than outside it.

**A new check was written for the class of mistake that cost most time
here**: `tools/check-exports.scm`. A splice that removes a definition
leaves a file that still *reads* and still *loads* - the loss shows up
only when something imports the name, as "Unbound variable" at run time.
That happened twice in one day (`*use-empty-active-region*` and `mark` in
simple.sld, both quiet casualties of my own cuts). The check reads each
library, takes its `export' clause, and asks Guile whether the library
*binds* each name - `module-local-variable` alone is not enough, it
answers a variable for a name no definition ever made. It was verified to
catch a removed definition, and on the way it found a pre-existing one:
`schemacs/apps/debugui.sld` exports names it never defines (the retiring
legacy app, left alone).

## Where step B's verification stands (2026-09-29)

Green: the suites (113 engine + 182 frontend), the pty battery 15/15 with a
new `kill-ring` check, `build.scm`, the name/export checks.

Every expectation that had to do with the ring's *arithmetic* or with what
a command does when the region is empty was taken from `emacs --batch`
rather than reasoned out, and that was the right call three times running:
`current-kill`'s rotation moves the pointer, so the third answer back is
not the third entry; `kill-new`/`kill-append` collapse to one entry; and
`C-w` on an empty region answers `("")` and no error. Each of those was
written down wrongly first.

M-y's non-yank case is the *older* Emacs behaviour ("Previous command was
not a yank") rather than Emacs 31's, which reads a kill out of the ring in
the minibuffer (`yank-from-kill-ring`): that needs `minibuffer.sld`, which
imports *this* library, so it cannot be called from here. Emacs has no
such constraint - its `.el` files have no import graph.

The `run-tests.scm` order-dependence recorded under step A is still there:
22 failures in that combined runner against 20 before this work, the two
extra being mark tests that pass when the file is run alone.
