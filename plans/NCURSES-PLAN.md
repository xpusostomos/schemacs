# Schemacs-ncurses: minimal terminal editor frontend

## Context

Schemacs (R7RS-Scheme Emacs clone, `/home/chris/GITE/schemacs`) has a mature, tested
headless core — the `(schemacs editor engine)` (gap-buffer-of-lines + line editor +
CDF char-index), `(schemacs keymap)`, and command machinery — but its only working
GUI is the GTK debugui placeholder; the real `emacs.sld` app can't render (the known
rect-propagation gap). Goal: prove the engine-centric thesis by building a **terminal
frontend on guile-ncurses** (installed, smoke-tested OK) with basic Emacs feel:

- open a file, edit it, save it
- self-insert typing, cursor motion (arrows, C-a/C-e/C-f/C-b/C-n/C-p, C-k at least)
- status line (buffer name, position)
- minibuffer with `find-file` / `save-buffer` prompts
- keymap dispatch through the existing `(schemacs keymap)` machinery

Deliberately NOT in scope (first cut): div-tree UI framework integration, kill ring,
prefix args, windows/splits, undo, syntax highlighting.

DONE SINCE (2026-09-26): the kill ring, prefix arguments (C-u) and undo
have all been implemented anyway. Undo followed GNU Emacs's model rather
than mg's storage: the undo list is a buffer property (a new field on
<text-editor-type> in engine.sld) shaped exactly like `buffer-undo-list`,
recorded by the insert/delete primitives, with the command loop placing
the boundaries; mg's undo.c corroborated the mechanism (an undo records
its own inverse, which is what makes redo work).

Also done: the buffer modified flag (`buffer-modified-p`, shown as `**`
or `--` at the front of the status line like Emacs's mode line) and the
save questions Emacs asks before work is lost - "Save file X? (y, n, !,
q, or C-g)" and, if the answer was no, "Modified buffers exist; exit
anyway? (yes or no)" on C-x C-c, plus "Buffer X modified; kill anyway?"
on C-x k. Undoing back past every change made since the last save marks
the buffer unmodified again, as Emacs does.

Also done: read-only buffers (Emacs's `buffer-read-only'). C-x C-q
toggles it (`read-only-mode`, with Emacs's messages), the text cannot be
changed or undone while it is on, the status line shows `%%' as Emacs's
mode line does, and a file that cannot be written is visited read-only
with Emacs's "Note: file is write protected" warning. The command loop
now catches the errors its commands signal and reports them in the echo
area, as Emacs's does - before this, any error a command raised took the
editor down with it.

Also done: incremental search (C-s / C-r), the editor's most-used
command. It follows GNU Emacs and mg, which agree on the parts that are
easy to get wrong: each search runs from the START of the current match
(so extending the pattern re-tries it where the last one began), point
ends at the far end of the match (past it forwards, at its start
backwards), a failed search leaves point alone, C-s at the last match
fails before it wraps, DEL takes back the last character typed, and C-g
takes back characters while a search is failing but abandons a
successful one. Leaving the search sets the mark where it started, so
C-x C-x (exchange-point-and-mark) gets you back. Matches are drawn as
you search - the one point is in in reverse video, the others in view in
bold, which is Emacs's `isearch' and `lazy-highlight' faces. Not yet
done: M-e (edit the search string), C-q (quote a character), regexp
search (C-M-s), and a match that spans a line break is found but only
partly highlighted.

Also done: a REAL MINIBUFFER. The event loop is now one re-entrant
`command-loop`, so a prompt is the same loop called again with a different
keymap and a different current buffer - GNU Emacs's `recursive-edit` - and
`exit-recursive-edit' / `abort-recursive-edit' leave it (a quit leaves with
a thunk whose call signals, so the signal travels out and abandons the
command that asked). The minibuffer is a real buffer (`minibuffer-contents',
undo disabled as Emacs disables it) and IS the current buffer while active,
so C-f/C-a/C-k/M-f/C-y/DEL work in the prompt with no code of their own. It
has `minibuffer-local-map' and `minibuffer-local-completion-map' built from
the global map's layers (sparse maps that inherit, as Emacs's do), history
on M-p/M-n, and `try-completion' / `all-completions' over a table, with
`read-file-name' completing file names against `default-directory' on TAB.
The four hand-rolled read loops are gone. One deviation: Emacs's
`read-char-from-minibuffer' answers on the keystroke itself; here the key is
typed and then RET, because answering on a keystroke needs a self-inserting
keymap layer that reports the character it matched, which the keymap library
cannot yet do. isearch still uses its own loop - moving it onto a keymap
override (`overriding-terminal-local-map') is the next step.

Also done: the end of a buffer that does not end in a line break.
The engine used to report point there on an empty line past the buffer
(the mode line read `L2 C1' for a one-line file), so `C-e' then `C-a'
was stuck - `beginning-of-line' moved point to the start of that empty
line, which was where point already was - and the frontend could not
draw the cursor there at all. That is fixed in the engine, which now
puts such a position at the end of the last line, exactly where GNU
Emacs puts `point-max'; the two display hacks that compensated for it
are gone. `next-line'/`previous-line' at the last/first line now move
point to the end/beginning of the buffer and say "End of buffer" /
"Beginning of buffer", as Emacs's do, and the echo-area cursor is no
longer dragged along by the message shown beside the input (a long one
used to pin it to the right edge of the screen). See ENGINE-FINDINGS.txt.

Also done: WINDOWS - C-x 2 `split-window-below', C-x 1
`delete-other-windows', C-x 0 `delete-window' and C-x o `other-window',
with the arithmetic of GNU Emacs's window API so that a split tiles the
frame exactly. The frame no longer holds one buffer, one scroll position
and one mode line: it holds a list of windows, as Emacs's frame holds a
window tree, and each window is a view of a buffer - which buffer, where
its display starts (`window-top-line', our `window-start'), where point
is in it (`window-point'), and the rectangle of screen it occupies
(`window-edges', `window-total-height' with the mode line and
`window-body-height' without). Commands act on the selected window; each
window has its own mode line, showing that window's buffer name and that
window's point, which is what makes two windows on one buffer readable.
Windows are not buffers, so the buffer's own identity moved onto the
buffer, as GNU Emacs keeps it: `text-editor-buffer-name' and
`text-editor-file-name' are the engine's, and `find-file' names a buffer
after the file it visits and leaves point at its beginning, as Emacs's
`find-file-noselect' does. A window's point is Emacs's `window-point',
which for the selected window is the buffer's own point and otherwise the
point that window is holding - so changing windows keeps each window where
it was.

Also done: C-x 3 `split-window-right', and with it the columns. The
geometry is the one a text-terminal GNU Emacs reports (`L=(0 1 40 23)
LB=(0 1 39 22) R=(40 1 80 23) RB=(40 1 80 22) TW=40 BW=39' for a frame
of 80 columns): the two windows share the width, an odd width giving the
extra column to the left one, and they are separated by the frame's
vertical border - one column, drawn down a terminal as `|' through every
row of the windows, their mode lines included - which belongs to the
window on its left, so that a window with a window to its right shows
text one column narrower than its width (`window-body-width'). Deleting a
window gives what it occupied to the windows it was combined with, which
is the window tree's answer in GNU Emacs; here it is the windows sharing
its row band, else those sharing its column band, else those beside it,
which agrees with Emacs for every layout I could measure (`window-edges'
out of a terminal Emacs for each sequence) - including a window that is a
whole column of the frame, whose columns go to all of the windows beside
it. What a window tree would also settle is the cyclic order of
C-x o after a deletion, and which of two siblings in a three-way split
grows: this frontend keeps its windows in the order they were made.

Not done yet, and next: the `*Completions*' buffer in a window below the
minibuffer's, which is what the splits were for. Also done since: the final line break. Saving a buffer that does not
end in one adds it, to the buffer and to the file, exactly as GNU Emacs
does by default (`require-final-newline', and `mode-require-final-newline'
which is what a file buffer's value comes from); the variable's other
values are implemented too, including the one that asks. The added break
is written in the file's own convention, so a CRLF file gains a CRLF.
See ENGINE-FINDINGS.txt for the byte-for-byte comparison with Emacs.

Also done since: MARKERS. A window's point and the buffer's mark are
now the engine's <marker-type>, which the insert and delete procedures
adjust, so they follow the text as GNU Emacs's do - edit above a
window's point in another window and it is still on the character it was
left on, and the mark an isearch leaves behind survives an edit in front
of it. Both were character indices before, which was wrong but not
obviously so until measured against Emacs (see ENGINE-FINDINGS.txt,
which also records why the engine's marker chain holds its markers
weakly). One deviation worth knowing remains: the file's line-break
convention is still on the frame rather than on the buffer, where Emacs
keeps it (`buffer-file-coding-system') - which is what the engine's own
`text-editor-line-break' would give us if the frontend stopped decoding
CRs by hand.

Remaining from the list: syntax highlighting, div-tree integration.

## Architecture decision

Bypass the `(schemacs ui)` div framework for v1: a single-window editor doesn't need
div trees, and debugui already demonstrates that hand-computed rects are the practical
pattern. Instead: new library `(schemacs ui platform ncurses)` + top-level
`main-ncurses.scm` that composes:

- **Storage**: `(schemacs editor engine)` via `run-editor-engine` — the engine IS the
  source of truth (Swing-shape: view never owns text). All edits go through
  `impl/*` parameters bound by `run-editor-engine`.
- **Input**: ncurses `getch` loop → key codes → schemacs keymap indices → commands.
- **Render**: walk engine lines (via CDF index→line/column) → `mvaddstr` per row,
  status line at bottom-1, minibuffer at bottom.

## Key findings from exploration (schemacs side)

1. **`run-editor-engine` is incomplete** (engine.sld:1219): binds 13 impl params,
   but `impl/set-cursor-index*` is never bound and 12 params (copy-string,
   get-char, delete-range, delete-from-cursor, scan-for-char/string, styles,
   selection) are `'*TODO*`. → My frontend parameterizes `impl/*` directly with
   its own bindings (engine procs + small helpers I write for delete/copy over
   the engine), NOT via run-editor-engine's defaults.
2. **Engine API usable directly**: `new-text-editor`, `text-editor-insert` (string/
   char/port), `text-editor-move-cursor ed ±n`, `text-editor-set-cursor (ed line col)`,
   `text-editor-get-cursor` → char index, `text-editor-get-line-column` (1-based),
   `text-editor-cursor-line`/`-column` (0-based), `text-editor-get-start/end-of-line`,
   `text-editor-char-count`. Line-break: `(text-editor-set-line-break! ed line-break-newline)`
   — actually default via `*default-line-break*` parameter is fine.
3. **File I/O**: nothing exists in-repo. Write it:
   load: `(call-with-input-file path (lambda (p) (text-load-port ed p)))`
   save: `(call-with-output-file path (lambda (p) (text-dump-port ed p)))`
   (`(scheme file)` not imported by engine — open ports at the frontend.)
4. **Keymap** (keymap.sld): build with `(km:keymap 'label (km:alist->keymap-layer `(...)) ...)`;
   chord alist syntax `((ctrl #\x #\s) . ,cmd)`; modifiers ctrl/meta; special keys as
   strings like "LEFT" via string->keymap-index. Fresh `(km:new-modal-lookup-state km)`
   per chord (state is single-use); step with `km:modal-lookup-state-step!` (returns
   `#t` = keep collecting, `#f` = action/fail executed via callbacks);
   `km:keymap-index->list` for diagnostics; self-insert via
   `(km:new-self-insert-keymap-layer #f on-success on-fail)` where on-success returns
   a command and the char is re-derived from the keymap state via
   `km:keymap-index-to-char`.
5. **Commands**: `(new-command name zero-arg-proc api-proc docstr)`; run via
   `(run-command cmd)`. api-proc mandatory (apply-command crashes without it).
6. **Minibuffer pattern**: debugui uses escaping continuations (call/cc stack,
   `simple-read-minibuffer` + `minibuffer-prompt-resume`, exit via RET command).
   My ncurses main loop must support handlers that escape via continuation —
   structure: outer `(let loop () ...)` event loop, commands may call/cc out and
   resume by re-entering `getch` loop. v1 simplification: modal minibuffer can be
   a *synchronous nested loop* (push minibuffer keymap + mode flag, keep calling
   getch) instead of escaping continuations — simpler and adequate for find/save.
7. **`uarg`**: no prefix-arg state exists anywhere; `C-u` out of scope v1.

## Files to create

1. `schemacs/apps/ncurses-editor.sld` — new library `(schemacs apps ncurses-editor)`:
   state record (engine buffer, file path, frame size, mode: normal|minibuffer,
   minibuffer prompt + entered text, message line), keymaps, commands, minibuffer,
   render, main loop.
2. `main-ncurses.scm` — top-level entry (mirrors `main-gui.scm` style):
   imports the library, calls `(main-ncurses)`.

## Implementation phases (build order)

**Phase 1 — storage + render skeleton (no keymap yet)**
- Library skeleton: imports `(schemacs editor engine)`, `(schemacs ui text-buffer-impl)`
  params, `(ncurses curses)`.
- ncurses init/end (`initscr`, `noecho`, `cbreak`, `keypad`, `curs_set`, `endwin`
  via dynamic-wind for safety).
- `render!`: compute view window (lines from top-row offset), for each screen row
  get the engine line (`text-editor-text-line-ref` / iterate lines gap-buffer via
  exported accessors) and `mvaddstr`; truncate at width; hide cursor in status rows.
- Status line: `-- <filename> -- L<line> C<col>` (from 1-based
  `text-editor-get-line-column`); draw with A_REVERSE at bottom-1.
- Cursor placement: screen row = cursor-line − top-row, col = cursor-column.
- Vertical scrolling: keep cursor visible (scroll when it leaves window).
- TEST: script drawing a loaded file without input (napms + endwin), verify layout.

**Phase 2 — file I/O + input loop + self-insert**
- `find-file path` → `new-text-editor` + `call-with-input-file` + `text-load-port`.
- `save-buffer` → `call-with-output-file` + `text-dump-port`.
- Main loop: `getch` → key descriptor → (Phase 3 keymap) with fallback:
  printable chars → `text-editor-insert`, then re-render.
- Basic motion commands operating on engine: C-f/C-b (`move-cursor ±1`),
  C-n/C-p (same column via `text-editor-set-cursor (ed line±1 col)` using
  remembered column), C-a/C-e (`text-editor-get-start/end-of-line` + set-cursor),
  arrows (mapped to same).
- Backspace/Delete: small `delete-char` helpers over engine line editor
  (check engine exports for delete; if absent, delete = re-set line text via
  line-editor APIs `text-editor-line-editor-ref` + gap-buffer procs — confirm
  exact approach against engine.sld:838-1058 during implementation).

**Phase 3 — keymap integration**
- Build `*default-keymap*` (chords above + arrows as "LEFT"/"RIGHT"/"UP"/"DOWN"
  strings) + self-insert layer, per keymap.sld idioms.
- Modal dispatch per chord: fresh `km:new-modal-lookup-state`, `step!` with
  callbacks; commands as `(new-command ...)` objects.
- ncurses key-code → keymap-index conversion: control chars (0-31) → `(ctrl #\letter)`
  (watch: ncurses returns `\n` for RET, `\t`, `\b`/127 for backspace); arrows via
  keypad → map KEY_LEFT etc. constants to `("LEFT")` style keymap indices.
- C-x C-f / C-x C-s chords via nested alist entries.

**Phase 4 — minibuffer + polish**
- Minibuffer: mode flag flips keymap to `*minibuffer-keymap*`, prompt string drawn
  at last row, typed text goes to a small engine buffer (or string), RET returns
  value (synchronous nested-getch variant — see finding 6), C-g cancels.
- `find-file` = prompt → load → message "Loaded X"; errors → message line.
- `save-buffer` = if no path, prompt; write; message "Wrote X".
- Message/echo area reuses minibuffer row.
- Wire `C-g` cancel, `C-x C-c` quit.

**Phase 5 — verification**
- Interactive: open a file with long lines + many lines, edit, save, diff vs
  original (expect only intended changes); motion across screenfuls; scroll;
  reload to confirm persistence.
- Terminal resize robustness: catch KEY_RESIZE or re-query; at minimum, initial
  size correct.
- `(load "./run-tests.scm")` still passes (123/5 baseline) — frontend must not
  touch engine/keymap internals.

## mg (public-domain MicroEMACS) as a reference implementation

`/home/chris/GITE/mg` — UNLICENSE (public domain), ~25K lines C. Same editor-layer
architecture as this frontend. Steal *semantics*, not storage:

- `word.c` (512 L): `forwword`/`backword`/`delfword`/`delbword` — the word-motion +
  delete-word logic, directly portable to engine `move-cursor`/`scan` calls
  (`inword()` char class from `chrdef.h:29` ISWORD → simple char-class predicate).
- `yank.c` (264 L): kill ring (single kill buffer w/ chunk-growth + KFORW/KBACK
  prepend/append) — the model for our kill ring.
- `basic.c` (583 L): `forwchar`/`backchar`/`forwline`/`backline` — motion edge
  semantics to mirror in engine-based commands.
- `echo.c` (1103 L): minibuffer prompt/echo edge cases worth reading for Phase 4.
- NOT worth stealing: `line.c`/`buffer.c` storage (schemacs engine is better),
  `tty*.c` (replaced by guile-ncurses).
- Phase 2/3 additions if time permits: `M-d`/`M-<backspace>` (word kill via
  delfword/delbword algorithm + yank kill ring), C-y yank.

## ncurses API specifics (verified from installed bindings)

- **Naming**: no `w*`/`mv*` variants — every proc takes the window FIRST, plus
  `#:y`/`#:x` keywords. `(addstr win str #:y y #:x x)`, `(refresh win)`,
  `(move win y x)`, `(clrtoeol win)`, `(erase win)`.
- **Screen size**: `(lines)` / `(cols)` — zero-arg procedures.
- **Input**: `(getch win)` — window REQUIRED. Returns a **char** for printable +
  control keys (`#\return`, `#\esc`, C-x = `(integer->char 24)` etc.), an
  **integer** for keypad keys (only when `(keypad! win #t)`): `KEY_UP/DOWN/LEFT/
  RIGHT/HOME/END/DC/BACKSPACE/NPAGE/PPAGE/RESIZE` (bare C names, exported), `#f`
  on timeout. Dispatch: `char?` → keymap path; `integer?` → special-key table.
- **Cursor visibility**: `(curs-set 0|1)`.
- **Attributes**: plain ints `A_REVERSE`/`A_BOLD`; `(attr-on! win attr)` /
  `(attr-off! win attr)`. (For strings, use `(addchstr ...)` with `inverse`-style
  xchar helpers if reverse-video status line proves awkward; else plain chars.)
- **Modes**: `(noecho!)`, `(cbreak!)`, `(keypad! win #t)`, `(nonl!)` — `meta!`
  is global.
- **Scrolling**: we do our own top-row offset rendering; `(scrollok! win #f)`.
- **Deprecation warning** (record-type name string) garbles first paint —
  run with `GUILE_WARN_DEPRECATED=no` (handle in `main-ncurses.scm` via
  `setenv` before importing ncurses, or document/echo).
- Text rendering uses plain Scheme strings via `addstr` (build is wide/UCS4).
- C-safety: wrap the whole session in `dynamic-wind` with `endwin` in the after
  thunk so a Scheme error can't leave the terminal raw.

## Risks / open points

- Engine line-iteration API for rendering: `text-editor-text-line-ref` +
  `text-line->string` exported — confirm per-line access pattern during impl
  (fallback: `text-editor-to-string` + string split is O(n) per frame; use only
  if line access proves awkward, acceptable for v1 small files).
- Delete helpers: engine may not export char deletion directly (only insert +
  line-editor); if `text-editor-delete-from-cursor` equivalent is missing, write
  it via line-editor gap-buffer APIs (engine.sld 838-1058 region).
- CRLF: engine line-break state machine handles CRLF; default LF is fine for v1.

====================================================================
PHASE 2 (2026-09-30): display abstraction - mirror Emacs's device split
====================================================================

STATUS, first cut done (2026-09-30): `editor/dispnew.sld` (the GOOPS
interface) and `editor/term.sld` (the curses driver) exist and are
wired: xdisp draws and keyboard reads through the generics, `with-
terminal` and the face/colour machinery have moved into term.sld, and
`ncurses.sld` is reduced to the entry point. All 310 unit tests pass
and the pty battery is at its baseline (27/28, the pre-existing
kill-ring). Remaining: phase 3 (frame/window genericize + output
slot), phase 4 (move keyboard's KEY_* decode and frame.sld's screen
size behind the interface), phase 5 (xfaces neutralization).

Problem, measured: the curses calls are few but wrongly placed. 21 draw
sites (addstr / attr-on! / attr-off! / init-pair! / color-pair) live in
xdisp.sld, which also converts faces straight into curses attribute bits
(A_BOLD | A_UNDERLINE | A_REVERSE | color-pair). frame.sld names its
records <ncurses-frame>/<ncurses-window> and keeps terminal input state
like esc-pending as frame slots. keyboard.sld reads getch/timeout!/KEY_*
for itself. That would put a GUI rewrite inside redisplay.

What Emacs actually does (verified in the 31 source):

  * xdisp.c never draws. It produces a glyph matrix - cells of a
    character and a face-id - and dispnew.c's update machinery compares
    and redraws rows. The drawing goes through `struct
    redisplay_interface' (dispextern.h): a per-display vtable of
    write_glyphs, clear_end_of_line, update_window_begin_hook,
    update_window_end_hook, draw_glyph_string, draw_window_cursor,
    flush_display, ...
  * term.c is the TEXT TERMINAL driver: terminal init (init_tty), the
    input hook (terminal->read_socket_hook = tty_read_avail_input), and
    the tty drawing (tty_write_glyphs & kin) behind the interface.
  * xterm.c / pgtkterm.c / w32term.c / haikuterm.c are the WINDOWED
    backends filling the same interface record and input hook.
  * xfaces.c realizes a face *per display*; on a tty it asks term.c
    what colors/attributes the terminal has.
  * term/xterm.el is LISP that talks to the terminal for its
    capabilities - a driver, terminal-specific by design, and kept as
    such.

So "mirror Emacs" here is a file-for-file split, not an invented
abstraction:

  schemacs/editor/term.sld      <- src/term.c   the curses driver
  schemacs/editor/dispnew.sld   <- src/dispnew.c  update machinery
                                  + the redisplay interface as GOOPS
                                  generics (see the departure note)
  schemacs/editor/xdisp.sld     <- src/xdisp.c  glyph production ONLY
  schemacs/editor/frame.sld     <- src/frame.c  <frame>/<window> with
                                  an `output' slot (output_data.tty)
  schemacs/editor/xfaces.sld    <- src/xfaces.c realize to a neutral
                                  spec; the driver maps to curses bits
  schemacs/editor/xterm.sld     <- term/xterm.el  unchanged (a driver)
  future GUI backend            <- pgtkterm.c's role: a new platform
                                  file filling the same interface and
                                  input hook (name it pgtk.sld - the
                                  Emacs GUI backend that is modeless
                                  GTK, which is the guile-gi direction;
                                  this also avoids colliding with our
                                  xterm.sld, which is term/xterm.el)

The plan, phase by phase, each phase ending green on the unit suites
and the pty battery:

  1. term.sld: move every curses call out of xdisp/frame/keyboard/isearch/
     minibuffer behind named procedures whose names mirror the interface
     fields - draw-run!, clear-end-of-line!, update-window-begin!,
     update-window-end!, draw-window-cursor!, flush-display!, beep,
     screen-size, read-input-event, tty-init!/tty-uninit! (with-terminal
     moves here). xterm.sld keeps its own direct terminal queries.
  2. dispnew.sld: the update loop + the GOOPS display interface; the tty
     implementation is a <tty-display> class and methods on the
     generics; xdisp hands rows of cells (char, face-id, continuation/
     fill decoration) to it and imports no curses.
  3. frame.sld: rename to <frame>/<window>, add the `output' slot holding
     the driver's terminal record; esc-pending and the like move into it.
  4. keyboard.sld: read through read-input-event; KEY_* decode moves into
     term.sld; events arrive display-neutral: (key ...), (resize rows
     cols), end-of-input.
  5. xfaces.sld: realize to the neutral spec; the driver maps spec ->
     A_BOLD / color-pair / init-pair!.

Explicitly NOT moving: the engine, buffer registry, keymaps, command
substrate, intervals, textprop, editfns, faces data, completion,
buff-menu/tabulated-list - they already have zero curses references and
stay at zero.

Also decided: the dead GTK frontend (schemacs/backend/guile-gi) is
retired against the new seam, not kept alongside it. And afterwards,
continue MG-PLAN.txt / BASIC-FUNC.md (the feature-gap list against mg).


DEPARTURE FROM EMACS, DELIBERATE (2026-09-30): GOOPS generics, not a
vtable record. Emacs's `struct redisplay_interface` is a C struct of
function pointers; the plan here spills it as a `<display>` GOOPS class
and generic functions named after the interface operations - write-
glyphs!, insert-glyphs!, clear-end-of-line!, update-window-begin!,
update-window-end!, draw-window-cursor!, flush-display!, clear-frame-
area!, plus the non-rif ones the editor needs (read-input-event, screen-
size, beep). One generic per operation, dispatched on the display
object; the curses backend defines methods for <tty-display>, and a GUI
backend adds a class and methods - no edit to xdisp or to the existing
backend. This follows the define-command precedent (Emacs is the reference
for behavior; Scheme's binding mechanisms are ours to use). GOOPS is
already used by the (retired) guile-gi backend, so it is no new
dependency. The portability caveat: GOOPS is Guile-only, but ALL the
interface definitions live in dispnew.sld alone, so a non-Guile port
re-implements that one library (the same trick as command.sld).