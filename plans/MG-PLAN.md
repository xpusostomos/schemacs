MG-PLAN: What to steal from mg (public-domain MicroEMACS) for schemacs-ncurses
Written 2026-09-25. Companion to NCURSES-PLAN.txt.

SOURCE: /home/chris/GITE/mg
LICENSE: UNLICENSE (public domain / unencumbered) — free to copy, modify,
redistribute, no attribution required. Verify per-file: most files carry a
"This file is in the public domain" header; some carry $OpenBSD$ CVS tags but
the tree's UNLICENSE covers the whole distribution.

WHAT MG IS
==========

~25,400 lines of C (src/*.c), OpenBSD lineage of MicroEMACS (Dave Conroy 1985,
via MicroEMACS 3.0 → mg 1987). It is an Emacs editor implementation WITHOUT
Lisp and WITHOUT display wizardry: explicit line structures, point ("dot") as
line+offset, hand-drawn display, kill buffer, echo line. 35+ years of battle-
testing of exactly the "editor layer above the buffer" that schemacs still
lacks.

STEALABLE SUBSYSTEMS, RATED AGAINST NCURSES-PLAN.TXT
====================================================

HIGH VALUE (port these):

word.c (512 lines)
  forwword / backword / delfword / delbword — word motion and word-kill.
  Each is a ~15-line loop: scan over non-word chars, then word chars, via
  forwchar/backchar + inword(). This is EXACTLY the word-motion gap flagged
  in the ncurses plan (delete-word needed a "char-class scan, ~50 lines").
  delfword algorithm (word.c:397): save dot position, purge kill buffer if
  last command wasn't a kill (lastflag & CFKILL), walk n words counting
  chars, restore dot, then ldelete(size, KFORW). The KFORW/KBACK direction
  flag is what makes consecutive M-d kills append into one kill entry.
  delbword (M-<backspace>) same in reverse with different buffer-edge rules.

  inword() (word.c:507) + chrdef.h:29 ISWORD macro:
      #define ISWORD(c) ((cinfo[CHARMASK(c)]&_MG_W)!=0)
  → becomes a simple char-class predicate in Scheme:
      alphanumeric (+ optionally _ and whatever we choose). The word
  constituent set is a policy decision — Emacs syntax tables say . and -
  are word BOUNDARIES (M-d on foo-bar kills only foo); mg's ISWORD is the
  simpler model. Start with mg's; upgrade to syntax tables later.

yank.c (264 lines)
  The kill "ring" (actually a single kill buffer with prepend/append):
  kdelete (reset), kinsert(c, dir) (KFORW appends, KBACK prepends),
  kchunk (grow in chunks — assumes consecutive kills arrive together),
  and the yank commands. Portable to ~100 lines of Scheme over a string
  or gap buffer. Modeled on the CFKILL "last command was a kill" flag
  protocol: consecutive kills merge, any other command starts a new entry.
  A true multi-entry ring (M-y cycling) is an Emacs extension beyond mg —
  keep the single-buffer model for v1, ring later.

basic.c (583 lines)
  forwchar / backchar / forwline / backline — the motion commands with
  correct buffer-edge semantics (return TRUE at buffer edges instead of
  erroring, negative-n delegation pattern, etc.). Port semantics into
  engine-based commands: move-cursor ±n, line±1 with remembered column.

MEDIUM VALUE (read before writing our own):

echo.c (1103 lines)
  Minibuffer prompt/echo edge cases: prompt width tracking, C-g abort,
  message-vs-prompt multiplexing of the echo line. Our synchronous modal
  loop is simpler than mg's, but its edge cases are documented here.

display.c (1592 lines)
  Its display model (per-window line cache: w_vstart offset, dirty flags,
  screen-to-buffer line mapping) is exactly the "render walk" of ncurses
  Phase 1. Worth reading before writing ours; the line-cache/scroll-offset
  policy is directly applicable even though the drawing calls differ.

undo.c (599 lines)
  Undo via command inversion + boundary flags (CFKILL-style "this flag"
  protocol marking undo boundaries). A clean recipe for a future phase.

  IMPLEMENTED 2026-09-26, but following GNU Emacs's model rather than
  mg's storage, since fidelity to Emacs is what buys Elisp compatibility
  (Emacs's `buffer-undo-list` is itself a buffer property and the bundled
  elisp/lisp/subr.el already calls it). mg's undo.c was still the
  cross-check for the mechanism, and the two agree on the part that
  matters: undo is a walk over an append-only list of inverses, and the
  inverse operations are recorded like any other edit, which is the
  whole of redo (mg's comment: "Only when we undo a deletion, the
  insertion will be recorded just as if it was typed on the keyboard").
  Also borrowed from mg: bracketing a group's inverse records with
  boundaries, no duplicate boundary at the head, and coalescing abutting
  insertions into one record.

region.c (705 lines)
  Mark/region handling (the `region` struct, copy/cut over mark and dot).
  Relevant when we add a mark — not in ncurses v1.

LOW VALUE (skip):

buffer.c, line.c — mg's storage: a linked list of fixed-size char lines.
  Schemacs's gap-buffer-of-lines + CDF engine is more modern and already
  tested. Steal commands and semantics, NEVER storage.
tty.c / ttyio.c / ttykbd.c / ansi.c — terminal layer, entirely replaced
  by guile-ncurses.
funmap.c / interpreter.c / autoexec.c — command naming/extension machinery;
  schemacs has its own command objects and will have Elisp.

MAPPED TO NCURSES-PLAN.TXT PHASES
=================================

Phase 2 (motion + editing): port basic.c motion semantics; add inword()
  predicate (from word.c:507 + ISWORD policy).
Phase 2/3 (if time permits): M-d / M-<backspace> via delfword/delbword
  algorithm + kill ring from yank.c model; C-y yank.
Phase 4 (minibuffer): echo.c as edge-case reference.

PORTING NOTES (C → Scheme over the schemacs engine)
===================================================

- mg's forwchar/backchar ≈ engine text-editor-move-cursor ed ±1 (returns
  success/failure at edges — same contract).
- mg's dot-line/doto ≈ engine cursor-line/cursor-column (0-based).
- mg's llength(line) / lgetc ≈ text-editor-get-end-of-line + line editor ref.
- mg's ldelete(size, KFORW|KBACK) ≈ engine delete-range/delete-from-cursor
  (frontend must implement these impl/* helpers itself — run-editor-engine
  leaves them as '*TODO* stubs) — wrap with kill-ring capture at our layer.
- The CFKILL/lastflag protocol maps to one boolean parameter in our command
  dispatcher: set #t after any kill command, cleared by every other command.
- inword() char class: make it a *parameter* (per-buffer word predicate),
  mirroring Emacs's syntax-table idea cheaply.

BOTTOM LINE
===========

mg proves the editor layer above the buffer is small: motion + words + kill
+ echo ≈ 3,000 lines of C ≈ 1,500 lines of portable Scheme, all public
domain. This is the strongest evidence that the ncurses frontend can reach
genuinely useful well within NCURSES-PLAN.txt's scope — and M-d, M-<backspace>
and C-y can come almost verbatim from word.c/yank.c algorithms rather than
being designed from scratch.
