ENGINE-FINDINGS: cursor-motion bugs in (schemacs editor engine)
Recorded 2026-09-25 during schemacs-ncurses Phase 1 work.
Status: ALL BUGS FIXED in engine.sld, with regression tests added to
engine-tests.scm (test group "schemacs_editor_engine_motion", 8 tests).
Full project suite after fixes: 123 pass / 5 pre-existing unrelated
failures (unchanged baseline).

FIXES APPLIED
=============

1. move-cursor's `(())` zero-value pattern matched against
   `gap-buffer-set-cursor`, which returns a true value - Guile errors
   "Wrong number of values returned to continuation (expected 0)".
   (MIT Scheme presumably tolerated the mismatch, which is why the
   upstream author never saw it.) The whole procedure was rewritten
   anyway (canonical model, below).
2. Canonical data model now: the lines gap-buffer contains one element
   for EVERY line (line n = gap-ref(n) for every n); the current line
   is "checked out" into the line editor with its identical copy left
   in the gap buffer; navigation = write-back-then-move-then-load.
   New internal procedures: text-editor-load-current-line,
   text-editor-write-back.
3. text-editor-dump-before's `end = max(0, line-1)` skipped a
   committed line - load + save lost a line for files not ending in a
   newline. Now end = cursor; dump-after skips only the stale copy of
   a modified line and writes the current line's terminating break
   explicitly (it lives in the stale record, not the line editor).
4. line-editor-freeze-part (freeze-line-after variant): iterated with
   logical gap indices (cursor..weight-1) into a zero-based vector -
   out of range for any mid-line cursor. Fixed with an index-base
   parameter. (Pre-existing bug: broke EVERY mid-line break.)
5. line-break-2-state (CRLF and LFCR): constructor arguments were
   swapped - the STRING went into the bv field - so bytevector-length
   crashed at the first CRLF break. CRLF/LFCR files could never work.
6. text-editor-insert's string case captured the line-break state
   machine procedure once per string, so CRLF state transitions were
   never observed on multi-character inserts (LF worked only because
   its machine is stateless). Now re-read per character.
7. write-back of a modified phantom line (typing past EOF) no longer
   introduces a line break; get-start-of-line/get-end-of-line
   corrected for the canonical model; line-editor-ref always reads
   the line editor.

NOT YET DONE (deliberate scope cuts, per NCURSES-PLAN)
======================================================
- delete helpers (impl/delete-from-cursor etc.) remain '*TODO*' stubs
  - Phase 2 work.
- text-editor-set-cursor with a <text-location> argument treats its
  1-based line/column values as 0-based (pre-existing quirk; the
  ncurses frontend will use integer indices).

REPRO EVIDENCE (pre-fix, all verified in-session)
=================================================
- "hello\nworld\nlast line" -> move-cursor -3 -> to-string gave
  "last lineworld\n" ("hello\n" lost); further moves crashed
  (u64vector-ref out of range -8, CDF desync).
- "hello\nworld\nlast line" -> load + to-string gave "hello\nlast
  line".
- set-cursor(ed 0 0) + insert crashed in unfreeze (line record #f,
  index -1).
- new-text-editor line-break-crlf + insert "one\r\n" crashed at the
  first break (bytevector-length on the string "\r\n").

The original analysis narrative is preserved below for the record.

WHAT WORKS (verified empirically)
=================================

- Load + dump round-trip is CORRECT for text ending in a newline.
  ("AAA\nBBB\n...\n" round-trips exactly.)
- text-editor-insert (string/char), text-editor-to-string, char-count,
  cursor-line accessor: reliable.
- After loading N lines: gap buffer holds N committed <text-line>s,
  gap cursor = N, current line lives in the line editor, changed=#t
  (or #f with empty editor if text ended with newline).

THE TWO INCOMPATIBLE CONVENTIONS ("state A" vs "state B")
=========================================================

The engine's procedures disagree about where "the current line" lives
relative to the lines gap-buffer cursor K:

STATE A (load path, force-line-break, get-cursor, cursor-line accessor):
  current line = the LINE EDITOR, at line index K.
  committed lines above = gap[0..K-1]; lines below = gap[K..weight-1]
  (= lines K+1..). get-cursor = cdf-ref(K-1) + editor-cursor, where
  cdf[i] = cumulative sum INCLUDING line i (cdf.sld cdf-fill), so
  cdf-ref(K-1) = start of line K. VERIFIED: get-cursor correct after
  load ("hello\nworld" -> 11) and t0 probe.

STATE B (unfreeze, dump-before `end = max(0,K-1)` skip, line-editor-ref
  fallback, get-start-of-line cdf-ref(K-2), get-end-of-line else-branch):
  current line = gap[K-1] "checked out" into the editor, stale copy
  left in the gap; dump/line-editor-ref substitute editor content for
  gap[K-1].

THE BUGS (all empirical, repro scripts in this session)
=======================================================

1. FIXED: engine.sld:1071 `(()) (gap-buffer-set-cursor lines cdf-cur)` —
   zero-values pattern, but gap-buffer-set-cursor returns a true value
   (gap-buffer-move-cursor returns 1). Guile errors "Wrong number of
   values returned to continuation (expected 0)". Fix: bind and discard
   `((_gap-buffer-set-cursor-rv) ...)`. (MIT Scheme presumably tolerated
   the mismatch, which is why upstream never saw it.)

2. text-editor-move-cursor LOSES DATA: it `gap-buffer-clear`s the line
   editor when the target line differs, WITHOUT freezing the current
   line first. Verified: load "hello\nworld\nlast line", move -3, dump
   -> "last lineworld\n" ("hello\n" gone); further moves crash
   (u64vector-ref out of range -8, CDF desync).

3. load + to-string LOSES a line for text NOT ending in a newline:
   dump-before's `end = max(0, (- line 1))` skips gap[K-1] (state B
   assumption) but after load the editor holds line K (state A), so the
   skipped line is a COMMITTED line. Verified: "hello\nworld\nlast line"
   -> to-string = "hello\nlast line".

4. text-editor-set-cursor (ed 0 0) + insert crashes in unfreeze:
   line-num=0 -> line=#f -> second fill loop indexes text-line-code-ref
   #f -1. Related: unfreeze's second loop condition `(<= col-num i)`
   runs one extra iteration when col-num = size (end-of-line), inserting
   a spurious duplicate char (or #f at the -1 index).

5. set-cursor(ed L C) sets gap cursor = L and clears the editor:
   under EITHER convention the subsequent unfreeze loads the wrong
   line (state A wants gap[L], state B wants gap[L-1] = the line ABOVE
   the requested one), and the cleared editor loses the old current
   line. Navigation via the exported API cannot preserve data today.

PROPOSED FIX (state A canonical)
================================

Canonical model: current line ALWAYS lives in the line editor, at line
index = gap cursor. Navigation becomes checkout-based:

  move/set-cursor to line T:
    1. if editor holds content: freeze WHOLE line editor (move editor
       cursor to start, then freeze-line-before) -> insert into gap at
       K, cursor advances to K+1, cdf-invalidate!(K).
    2. gap-buffer-set-cursor lines T
    3. CHECKOUT: if T < weight, load gap-ref(T) into the editor and
       REMOVE it from the gap (gap-buffer-delete, weight-1), so the gap
       holds exactly the lines above (0..T-1) and below (T+1..); set
       editor cursor = column; cdf-invalidate!(T).

  Then, for consistency:
  - unfreeze -> becomes the checkout step (load gap-ref(K), delete from
    gap, not gap-ref(K-1) with stale copy).
  - dump-before: `end` = K (dump ALL committed lines above), no skip.
  - dump-after: unchanged (editor-after + gap lines after cursor).
  - get-start-of-line: cdf-ref(K-1) (not K-2).
  - get-end-of-line else-branch: cdf-ref(K-1) + editor weight.
  - line-editor-ref: always read the editor (drop the gap fallback).
  - force-line-break unchanged (already state A).
  - fix unfreeze second-loop boundary `(<= col-num i)` -> `(< col-num i)`.

Scope: ~6 procedures in engine.sld, plus new regression tests
(round-trip for trailing-newline and no-trailing-newline text, cursor
walk forward/backward over a 5-line buffer with marker inserts at each
line, C-a/C-e equivalents). Estimated 1-2 working sessions. The two
existing engine tests (record/playback) must keep passing.

These are upstreamable bug fixes for the schemacs project regardless of
the ncurses frontend (the maintainer's own cursor-motion commit,
21d050f "cursor motion" 2026-06-28, is the code in question; the engine
test suite does not currently exercise motion).

FURTHER FIX, 2026-09-26: character indexing dropped the first
character of a line (and of every single-line buffer)
================================================================

Found while finishing the ncurses frontend's prefix-argument and
kill-ring work: `C-k` then `C-y` on a one-line buffer lost the text
entirely, and `text-editor-copy-string` returned "ne two" for
"one two".

ROOT CAUSE (engine.sld, text-editor-make-cdf-fill-until)

The CDF generator stopped as soon as the running total reached the
target index:

    ((and (< accum accum-max-value) (< cursor weight)) ...)

`accum` is the CDF value of the line BEFORE the one being generated,
so the bucket of the line containing the target index is exactly the
one whose `accum` EQUALS the target. Testing `<` left that bucket
ungenerated, so `cdf-find` saw `top <= n`, reported the index out of
bounds, and `text-editor-get-char-index` fell into its "past the end
of the last committed line" branch and returned #f.

Consequence: every character index that begins a line was
unresolvable, index 0 of any buffer above all - including index 0 of a
single-line buffer, which has no line break to anchor the CDF.
`text-editor-copy-string` is a loop over `text-editor-get-char-index`,
so it silently skipped that character: kills captured short text
(`C-k`/`C-y` lost data), and the frontend's word-motion predicate
`%inword-at` mis-read the first character of every line.

FIX: `(< accum accum-max-value)` -> `(<= accum accum-max-value)`.

Regression tests: test group "schemacs_editor_engine_char_index" in
engine-tests.scm (4 tests: first char of a single-line buffer, whole
single-line copy, first char of every line of a multi-line buffer,
index past the end still #f).

ALSO: engine-tests.scm was never registered in run-tests.scm, so the
12 motion regressions recorded above had not been running in the suite
at all. Both it and the new frontend test file are now registered;
suite totals are baseline 123 pass / 5 pre-existing failures, plus 18
engine and 26 frontend tests.


==================================================================
FINDING (2026-09-26): the end of a buffer that does not end in a
line break was reported on a line the buffer does not have
==================================================================

Symptom (reported against the ncurses frontend): "movement is weird.
Sometimes if I go the end with C-e it refuses to go to the beginning
with C-a. If the cursor is at the end C-b takes it to the beginning.
C-b again takes it to the 2nd last character."

Cause: `text-editor-index-line-offset` resolves a character index to a
line by filling the CDF and binary-searching it with `cdf-find`. When
`cdf-find` cannot place the index - which is exactly the case for the
index at the very end of a buffer whose last line has NO line break
after it - the code answered with the lines gap-buffer WEIGHT as the
line number:

    (values (gap-buffer-weight lines)
            (max 0 (- ch-index (cdf-maximum cdf))))

`text-editor-line-count` counts a line at that index only when the
gap-buffer cursor is there (the "new empty line" a trailing line break
starts), so for the buffer "abc" the answer was line 1 when the buffer
has one line, index 0. Consequences, all of them wrong the same way:

  - `text-editor-get-start-of-line` at the end of "abc" returned 3,
    the position itself, so `beginning-of-line` moved point NOWHERE:
    C-e then C-a was stuck (the report above).
  - `text-editor-get-end-of-line` likewise stayed on the phantom line,
    so the mode line read `L2 C1` for a one-line file.
  - The frontend could not draw point there at all:
    `cursor-screen-position` looked up a line the buffer does not
    hold, got #f, and left the cursor unpainted - it appeared to sit
    at the beginning of the screen and refuse to move.
  - `text-editor-set-cursor` clamped the line to the gap-buffer
    weight, so moving down from the last line (`next-line`) put point
    at index 4 of a three character buffer, past the end of the text.

GNU Emacs puts `point-max' at the END OF THE LAST LINE here (a
buffer's last line has no break, so no line follows it), which is what
`(line-number-at-pos (point-max))' = 1 for a one-line buffer means.
The two cases are distinguishable exactly by whether the lines
gap-buffer cursor is at its weight: if it is, the current line is the
new empty line a trailing break started (a line of its own - the
buffer "abc\n" really has two lines); if it is not, the index is the
end of the last committed line.

FIX: in `text-editor-index-line-offset`'s `cdf-find` miss branch,
report the last committed line at its end when the gap-buffer cursor is
not at the weight; and in `text-editor-set-cursor`, clamp the line to
the last line the buffer holds (the weight only when that line ends in
a break). The frontend's two compensating hacks - the `at-end?'
correction in `cursor-screen-position` and the one in
`minibuffer-cursor-column' - are deleted; both are dead once the
engine reports these positions correctly, and neither could have
covered the `set-cursor' case.

Also fixed in the frontend, found while measuring this: the echo-area
cursor was placed at `minibuffer-cursor-column' PLUS the length of the
echo-area message, so any message dragged the cursor right - a long
one (the completion candidates) pinned it to the right edge of the
screen, where no amount of C-a/C-e/C-b appeared to move it. Emacs's
`cursor-in-echo-area' leaves the cursor at point in the input with the
message drawn after it; that is what it does now.

And: `next-line`/`previous-line` at the last/first line now behave as
Emacs's do - point moves to the end of the buffer (or its beginning)
and the command reports "End of buffer" / "Beginning of buffer" in the
echo area, instead of silently doing nothing.

Regression tests: test groups "schemacs_editor_engine_end_of_buffer"
(8 tests) in engine-tests.scm and "schemacs_ncurses_editor_cursor_position"
(4 tests) in ncurses-editor-tests.scm.


==================================================================
DONE (2026-09-26): markers - positions that follow the text
==================================================================

The engine had no markers: a window's point and the buffer's mark were
plain character indices, so they did not follow the text. Measured
against real Emacs for the same sequences:

                                  ours (before)   Emacs
  a window's point, with 2 chars inserted before it   5    7
  the mark, with 2 chars inserted before it           5    7
  point across `save-excursion' with an edit inside   4    6

The consequence was not cosmetic: isearch leaves the mark where a
search started ("Mark saved where search started"), so search, edit
above the mark, C-x C-x landed on the wrong character; and a window
left alone while another window edited the same buffer came back to
the wrong place. It also blocked the larger plan, because
`save-excursion' - the most-called missing Emacs name across the files
we measured, needed by 6 of 6 - cannot be implemented correctly
without markers: its whole point is that the saved point survives the
edits the body makes.

WHAT WAS ADDED

  - `<marker-type>`: a buffer (or false, "points nowhere"), a character
    index, and Emacs's marker insertion type.
  - The buffer's marker chain (`text-editor-markers`), walked by
    `adjust-markers-for-insertion!` / `adjust-markers-for-deletion!`
    from the two mutation primitives. Emacs's own names, from
    insdel.c. Both hooks are single points: `text-editor-insert`
    already knows where the insertion began and ended (which covers
    strings, characters, lines, a line break typed or forced by the
    line-break state machine), and `text-editor-delete-from-cursor`
    knows the deleted range - and undo replays through both, so undo
    adjusts markers for free.
  - `new-marker`, `copy-marker`, `marker-position`, `marker-buffer`,
    `marker-type?`, `set-marker!` (false position = nowhere, which is
    Emacs's `(set-marker m nil)`), `set-marker-insertion-type!`,
    `mark-marker`.
  - The mark is now a marker. `text-editor-mark` still answers with an
    integer or false, as Emacs's `(mark)` does; `mark-marker` gives
    the marker itself, which is the same object every time.
  - The frontend's window point is a marker, so `C-x o` returns each
    window to the character it was left on.

The boundary rules are Emacs's, checked one by one with
`emacs --batch` before writing the expectations: inserted text before
a marker carries it; inserted text after it does not; text inserted
exactly at a marker leaves it there unless the marker's insertion type
is true; deleted text collapses the markers inside it to the start of
the deletion, and moves the ones after it back.

WHY THE CHAIN IS WEAK, AND NOT STRONG

Emacs keeps markers in a chain per buffer that does NOT keep them
alive: the chain is invisible to the mark phase and the sweep phase
unchains whatever was not marked, so a marker that nothing refers to
is collected and its place in the chain goes with it. Measured on real
Emacs (100k markers created and dropped, timing 50 insertions in the
same buffer):

  no markers                                 0.0000 s
  100k markers dropped, after (garbage-collect)  0.0001 s
  100k markers held in a list                0.0291 s
  ... and with GC suppressed while creating them 0.0221 s

The third line is what a strong chain would look like; the second and
fourth show that the chain is pruned by the collector and that until
it runs they are still being adjusted. Scheme has no sweep hook, so
the chain holds markers weakly instead (`(schemacs weak)`, a weak set
that no Scheme standard below R7RS-large provides - SRFI-124
ephemerons and SRFI-125 hash tables are the standardised ones, and
Guile 3.0.11 has weak vectors, weak hash tables and guardians but no
ephemerons). A marker that nothing else refers to is therefore
collected and drops out of the chain by itself.

==================================================================
FIXED (2026-09-27): backwards deletion at the end of a buffer deleted
one character fewer than it reported
==================================================================

Found while testing the markers, which trust the count that a deletion
returns - as the undo code does.

  (text-editor-insert ed "abcd")
  (text-editor-set-cursor ed 4)          ; the very end, no trailing break
  (text-editor-delete-from-cursor ed -2)
  => reports 2, buffer is "abc", count 3, cursor 3   (should be "ab", 2, 2)

The same deletion one character further in is correct ("abcd" at 3 with
-2 gives "ad"), and so is the same deletion at the end of a buffer
whose last line DOES end in a line break ("abcd\n" at 4 gives "ab\n").
Instrumenting `%text-editor-delete-backward` showed why: at the end of
a buffer whose last line has no break, the engine is still in its "new
empty line past the end" state - the line editor is empty, its cursor
is 0, and the lines gap-buffer cursor is 1 - so the `(<= n col)` test
fails and the deletion takes its line-merging path, removing the break
that is not there and then deleting one character by recursion.

That state is the same phantom line that `TEXT-EDITOR-INDEX-LINE-OFFSET`
was fixed to stop reporting earlier today (see the finding above): the
insert path still leaves the cursor on a new empty line when it appends
the line it was editing, and the delete path reads the line editor
directly rather than asking where the cursor is. So the bug is not in
the deletion arithmetic but in the model: a buffer whose last line has
no line break should not have a new empty line as its current line.

Two consequences, both bad: the undo entry for such a deletion recorded
2 characters to reinsert where 1 was removed (so undo corrupted the
buffer), and the marker adjustment shifted markers by 2 where the text
had moved by 1.

FIXED by making the append agree with the line model, in
`TEXT-EDITOR-WRITE-BACK': when the line being edited is a new line past
the end of the lines gap-buffer, the frozen line is appended and the
cursor now STAYS ON IT. It carries no line break - a break typed on such
a line is handled by `TEXT-EDITOR-FORCE-LINE-BREAK', which commits both
halves - so no line follows it, and the end of the buffer is the end of
that line, as it is for Emacs's `point-max'. Advancing onto an empty
line after it was advancing onto a line the buffer does not have, and
from then on the engine answered two ways about where the cursor was:
`TEXT-EDITOR-INDEX-LINE-OFFSET' said the end of the last line, while the
line editor held an empty line. Everything that reads the line editor -
the delete procedures, `TEXT-EDITOR-CURSOR-COLUMN' - got the second
answer. Staying on the line also preserves the cursor exactly, because
the reload at the end of the write-back then puts the line editor cursor
at the column being edited at, where the empty line had put it at the
end of the buffer whatever column it had been at.

Verified against a real Emacs, case by case:

                                        Emacs            ours (now)
  "abcd" end, delete -2              ("ab" 2)          ("ab" 2)
  current-column at the end of "abcd"    4                 4
  line-number-at-pos (point-max)         1                 1
  mid-line delete -1 from index 2   ("acdef" 1)       ("acdef" 1)
  "abcd\n" end, delete -2             ("abc" 3)         ("abc" 3)
  undo of the end deletion            "abcd"            "abcd"

and the line break case is unaffected: a buffer whose last line does end
in a break really does have an empty line after it, and the cursor can be
on it (`line-count' counting one more there is right, and the condition
for it is now stated in that function's docstring).

Regression tests: the "schemacs_editor_engine_end_of_buffer" group grew
from 8 tests to 15, covering the line count, the column, both directions
of backwards deletion, the deletion at the end, the undo round trip, and
the cursor surviving a write-back made while it is in the middle of the
line.


==================================================================
FIXED (2026-09-27): saving now adds the missing final newline, as
Emacs does
==================================================================

Saving a buffer whose file had no line break at the end leaves it
without one, where GNU Emacs appends a newline. Verified with a real
Emacs: visiting a file holding "abcd", deleting two characters and
saving gives "ab\n" there and "ab" here; with a file that already ends
in a line break both give "ab\n".

The rule is Emacs's `require-final-newline', together with
`mode-require-final-newline' (t, and what the file-visiting major modes
set the buffer's value from - the variable's own default is nil, which is
why a file buffer's effective value is t). The frontend now implements
it as the variable, with Emacs's values:

  t           add it when the buffer is saved
  visit       add it when the file is visited
  visit-save  add it at both times
  any other   ask whether to add it, when saving
  #f          never add one

The conditions are Emacs's too, out of `basic-save-buffer-1' and
`after-find-file': a buffer that is not empty, is not read-only, and does
not already end in a line break. The line break is inserted into the
buffer itself (so the buffer holds what the file will hold and is
unmodified again once saved), through the engine's own insert, so undo
and any markers follow it. At visit time the same rule is applied to the
text being loaded, which leaves a visited buffer unmodified. The asking
case uses a new `y-or-n-p' with Emacs's message, "Buffer %s does not end
in newline.  Add one? " - `y-or-n-p' and not `yes-or-no-p', as Emacs
chooses there.

Verified in bytes against a real Emacs, visiting and saving:

  file before            Emacs after save        ours after save
  "ab"                   "ab\n"                  "ab\n"
  "ab\n"                "ab\n"                  "ab\n"
  "ab\r\ncd"           "ab\r\ncd\r\n"       "ab\r\ncd\r\n"

so the added line break is written in the file's own convention, as the
frontend's CRLF encoding requires. An earlier pty comparison appeared to
show Emacs leaving a CRLF file alone; that run's save had not taken
effect, and the bytes comparison above is the one that settles it.

Regression tests: "schemacs_ncurses_editor_final_newline", 10 tests -
the save-time addition (to the buffer and the file, leaving the buffer
unmodified), a file that already ends in a break, an empty buffer, a
read-only buffer, each value of the variable, the CRLF file, and the
visit-time rule as a function of the text.

=========================================================================
MODE LINE: two things our own code got wrong, found by implementing
`mode-line-format' (2026-09-27)
=========================================================================

Both were found by evaluating the format the way GNU Emacs does rather than
assembling a string by hand. Every value below was *measured* from
`emacs -Q -nw` in a pty with the answer written out from
`(format-mode-line ...)` to a file - not reasoned about. `format-mode-line`
returns "" in a batch Emacs (there is no display), so batch is useless here
and the terminal is the only way to ask.

FIXED. The modification indicator was wrong for one of its three states.

  The mode line's first two cells are two constructs, not one. In
  `bindings.el':

      mode-line-modified = ("%1*" "%1+")

  `%*' gives `%' for a read-only buffer whatever its modification state;
  `%+' gives `*' for a modified buffer. So:

      state                    Emacs    ours was   ours now
      clean                    --       --         --
      modified                 **       **         **
      read-only, clean         %%       %%         %%
      read-only AND modified   %*       %%   <--   %*

  Our `modified-indicator' tested read-only first and returned `%%'
  unconditionally, so it could never show `%*' - and its comment
  rationalised the bug ("`%*' yields `%' ... before it considers the
  modification flag", which is true of `%*' alone and beside the point
  when `%+' is the second half). A test asserted `%%' for that state, so
  the bug was pinned in place.

FIXED. `%c' counts from zero; our mode line counted from one.

      (format-mode-line "%c")   at the start of a line:  Emacs "0"
      (format-mode-line "%C")   the same construct one-based: "1"

  The engine's columns are one-based, as a screen position must be, so the
  construct subtracts. The editor's mode line therefore reads `C0' where it
  read `C1'. `%C' is the one-based construct and is available to any format.

The field-padding rules, which are not documented and had to be measured:

  %6l      -> "     1"     a number pads on the LEFT
  %3l      -> "  1"
  %12b     -> "probe       "   anything else pads on the RIGHT
  (6 "%l") -> "1     "     the (N ...) *element* form pads on the RIGHT
                           even for a number - a different mechanism from
                           %N<spec> and a different result

Not implemented, and printed as they stand (Emacs prints a construct it does
not recognise the same way): the buffer-percentage constructs %p/%P/%o/%q,
the coding systems %z/%Z, the process %s, and the recursion depth %[/%].
`%-' ("enough dashes to fill the mode line") needs the line's width, which
is only known while drawing, so the drawing code pads instead.
