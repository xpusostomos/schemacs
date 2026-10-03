
 ~1,300 lines  re-
hosting    of            frontend                                                                      would 
need    specs    tests                                     
valuable,     behaviour                                                                   
 ~1,500 lines  (simple.el/window.el/minibuffer.el/isearch.el/  
part          layer     files.                                                                  el-  
duplicated    editor    shaped)   of   
the           the       commands                                         
   the engine work (markers, undo, CDF, read-only,   lower 
layer   layer     line                                                                    C- 
intended      core    model)      already 
the   the                                                                         
   terminal, rendering, input,  
architecture  key            dispatch,                                                                   command   
intended      backend   loop           fits 
the      the                                                                         
Where the "simple port" premise  worth knowing before you bet on it

- Strings are mutable in Elisp (aset on a string, store-substring);
R7RS strings are immutable. You need a mutable-string representation.
Real friction, hits early.

- nil is () and false, and eq/equal don't match Scheme's. (eq 1 1) can
be true; equal is structural over strings/vectors.

- Dynamic binding for defvared symbols. The saving grace: modern .el
files are lexical-binding: t, which maps onto Scheme almost directly.
But let of a defvar'd symbol must still be dynamic, and that's specpdl
historically the thing that killed guile-emacs, the last serious
attempt to run Emacs's Lisp on Guile. Your translator architecture
(reuse Guile's evaluator, expand macros with Emacs's own macroexp.el)
sidesteps a chunk of what killed it, which is why I think this path is
genuinely live rather than a fantasy.

- Markers, overlays, text properties all adjust on edit. Our
window-point is already a documented deviation here (an index, not a
marker). Emacs's Lisp assumes adjustment everywhere. Small code,
pervasive consequence.

- The display side is a real interface too: Emacs's Lisp calls
redisplay, window-start, pos-visible-in-window-p, line-pixel-height,
and the display text property. A tty needs far less of xdisp.c than X
but not none.

------------------------

does semantics breaks 

Caveat: that undercounts, because I only inventoried the frontend's commands and the elisp  not
the frontend's plain procedures (read-file-name, try-completion, yes-or-no-p,
read-char-from-minibuffer), which are real answers to real Emacs names. So treat these as a floor.

The good news, stated plainly

The primitives that editor elisp touches most are the ones we have. The whole buffer/text 
point, goto-char, insert, delete-region, buffer-substring, buffer-string, forward-char,
bolp/eolp/bobp/eobp, line-beginning-position/line-end-position, current-column, mark/set-mark,
kill-region, search-forward, text properties (VBAL), buffer-name/buffer-file-name, buffer-read-only, and now the entire window API we just  is there. That's not an accident: it's exactly what the engine and this session's work added. It's also why the simple files land at 60% already.

And the misses at that level are embarrassing little holes: the elisp env has * + - < <= = > >= but 
not / or 1+, abs, min, max, not, null, length, zerop. Trivial names, real coverage.
                                                                                                    
The gaps that actually matter
                                                                                                    
Deduplicated across all six files, everything genuinely absent falls into ~10 subsystems:
                                                                                                    
- Regexp + match  re-search-forward, match-beginning/-end/-string, looking-at, replace-match, string-match, case-fold-search. The biggest single piece (Emacs's own dialect). Also the one most often substitutable during a hand-port: tabify's use is "find leading whitespace", which is a char scan for us.
- save- the single most-called missing name, needed by 6 of 6 files. A C special form in Emacs; for us it's save point+mark, restore on unwind. Tiny, and it unblocks everything.
- The  region-beginning/region-end/use-region-p/push-mark/transient-mark-mode. We have the  mark, so region = mark..point is expressible; what's missing is the machinery and the "active" flag. 5 of 6 files.
-  narrow-to-region, save-restriction, widen. Absent; needs point-min/point-max bounds in the engine.
-  copy-marker, set-marker, and adjustment on edit.
-  make-overlay, overlay-put/-get, move-overlay. The highlighting mechanism.
- Buffer-locals and buffer  setq-local, make-local-variable, kill-local-variable, with-current-buffer, get-buffer-create, bufferp.
- Column/indent  move-to-column, indent-to, indent-tabs-mode.
- Syntax  skip-syntax-*; our word motion is a char class, which is the same idea without the table.
-  add-function, advice-add (3 files), and further out: timers/sit-for, display-buffer, tabulated-list-*.

Of those, only regexp, overlays and markers are genuinely big. save-excursion, the region, narrowing, buffer-locals and the column arithmetic are each  the reason they show up everywhere is that elisp assumes them, not that they're hard.

So: at what point is it "easy peasy"?

When a runtime shim answers ~90% of the names an editor-ish file calls. The shim is one  Emacs  our procedure, with explicit (absent) / (stub)  starting with the ~60 aliases into the engine and frontend that already exist (point, goto-char, insert, delete-region, buffer-substring, forward-line, current-column, line-*-position, mark, set-mark, buffer-name, the window ). And here's the useful part: that table is simultaneously the coverage metric, the work list, and the thing that makes a port a rename instead of a rewrite. With it in the repo, "how close are we" becomes one command that prints the port-ready % for any file you're thinking of  which is exactly the number you asked for, recomputable as we go.

Rough sizing, in work units rather than fake dates: the alias pass is mechanical (big coverage jump per hour, and save-excursion alone unblocks 6 of 6 files); the region/narrowing/buffer-locals/column group is a small focused batch; regexp, overlays and markers are three projects, each the size of the work we did for isearch or windows this session.

And the level-2 strategy that follows from the numbers: port the small self-contained editor files  tabify, misc, rect, thingatpt, sort, register, page-alikes. Each is a real feature gained, each one exercises the shim, and each one grows it empirically rather than by guesswork. The moment the shim gets near-complete is also the moment the machine could start doing the  which is the level-1 conversation again, arriving by a different road.

Want me to build the shim table (the aliases + the coverage tool) as the next piece of work? It's small, it's immediately useful, anporting first stealing setmarkers name table small Advice tables arithmetic objects Overlays Markers Narrowing region excursion data 40built surface env  isearch.    
23%      89         380            4776  el   
 replace.    
25%      88         358            3476  el   
 thingatpt.    38%      48         126            878   el 
 rect.    42%      71         169            1022  el      
 misc.    50%      56         111            331   el      
 tabify.    62%      18         29             104   el    
       external   coverage resolvable names lines file     
Where we are, per file

resolvable = the name resolves today (frontend command or elisp-env primitive) or the capability exists under a different name (point, goto-char, insert, delete-region, buffer-substring, search-forward, kill-region, propertize, the window ):
API


---------------------------------

Where the C/Elisp line actually falls

Your guess is right. The C part of completion is: try_completion/all_completions/test_completion (matching a string against a table), the minibuffer read loop (read_minibuf), and the raw window operations display-buffer sits on. Everything about choosing, sorting and showing the candidates is  minibuffer-completion-help, completion--do-completion, completion--all-sorted-completions, completion--insert-strings, the completion styles, and display-completion-list +                    completion-setup-function (those two live in simple.el, not even minibuffer.el).                                                                                                                       The relevant slice measures ~530 lines of Elisp: 187 for minibuffer-completion-help, 136 for       completion--do-completion, 56 for the buffer setup, 43 for completion--insert-strings, plus ~80 for sorting and 
impediment: minibuffer-next-completion, minibuffer-choose-completion
what it really wants: M-<down>/M-RET selection
verdict: optional; needs a keymap and a point in that  we have both notions

That's the entire list. Two small things to build, six known rewrites, and the rest is deletion.

Note what's already carrying the weight: insert, point, point-max, buffer-substring, char-after, goto-char, forward-char, message, ding, the whole minibuffer (contents, keymaps, history, prompt), try-completion/all-completions/common-prefix, and the window  split-window-below, set-window-buffer, window-buffer, window-width, window-point, delete-window. with-current-buffer-window reduces to exactly those. So the last two sessions'  windows in  was the prerequisite for this steal, and I didn't know that when we started it.

So, at what point?

You can start now, one feature at a time. The whole-file percentages were misleading because they count every symbol including whole categories a terminal port deletes (mouse, buttons, faces-as-graphics, field properties, multiple frames, processes, advice). The right unit of measurement is what one chosen target  and for this target it's a table above that fits on a screen.

And that's the mechanism you're looking for: each port's impediment list is short, specific, and mostly non-overlapping with the last one. Steal completion and you'll have built save-excursion, a way to display a second buffer, and window-presence  three primitives that then show up in the next ten files you steal. Do that a few times and the primitives layer grows from demand instead of from guesswork, and the "coverage" question answers itself.

Concretely, the union you'd have after three or four such ports would be: save-excursion, condition-case/unwind-protect/catch/throw, buffer objects + locals, text-properties exposed to Elisp, region/mark machinery, and the regexp-and-match-data  which is precisely the gap list from the earlier measurement, arrived at from the other end.

So my recommendation stands but with a better order than I gave before: do the completion port next, as the actual feature (it's about the size of the windows work, it replaces the ugly candidate line with a real *Completions* buffer, and it manufactures the first three primitives). Then pick the next file by what you want next, not by what looks most Emacs-complete. Want me to plan that  the massaged Scheme shape of minibuffer-completion-help and the ~three primitives it  before I write it?needs port group queries needs particular work API buffer the basic style. A good ~40% of that is                                                mouse/mouse-face/button/field-
impediment: setq-local (in completion-setup-function)
what it really wants: buffer-locals for the *Completions* mode/keymap
verdict: skip in v1, or a tiny alist
property/lazy-hilit code that simply doesn't exist on a terminal, so  it's ~350 lines of Scheme after the massage.                                                                                                                                                       
impediment: minibuffer--completion-prompt-end, ding, zerop, substring, consp, when-let*
what it really wants:
verdict: one-liners / macro rewrites
The impediments, from the actual call graph                                                        

I dumped every call minibuffer-completion-
impediment: completion-all-completions, completion-boundaries
what it really wants: the completion styles
verdict: keep only basic, call our try-completion/all- which we wrote this session
completions help makes. Stripping 
impediment: completion--metadata, completion--field-metadata, field-char, field-end,
completion-lazy-hilit
what it really wants: text-property metadata for candidate highlighting
verdict: skip in v1 (we highlight by index); later it's an adapter over VBAL
out locals, macros and the mouse 
code, here's the whole list of things that aren't already 
impediment: save-excursion
what it really wants: save/restore point (and mark)
verdict: a 5-line  and needed by nearly every function you'll steal
macro answerable:
                                                                                                 
impediment: get-buffer-create, with-current-buffer, with-current-buffer-window
what 
impediment: get-buffer-window, minibuffer-hide-completions
what it really wants: "is the completions window up? take it away"
verdict: small: walk the window list, delete-window
it really wants: show a second buffer in a second window                                    
verdict: collapses under your relaxed standard. Our windows already show any  so it's "make
an editor for the *Completions* text, name it, split, show it". No buffer registry needed.
editor 300Elisp 

---------------
DUPLUICATION

Direct answer: it's a shell, not a rival. Here's the whole list of what's in there that we don't have.

The six things

what's there: A window  window-parent-frame, 
what's there: The impl/* parameters + three view constructors
why it matters: The seam that keeps the editor layer independent of the display. We invented our own
seam instead, which is exactly why run-editor-engine sits unfinished.
ours today: our own shape

And here's what we did not  which is most of it

I grepped it for everything we've built.  zero. try- zero. kill- zero.  zero. kill-line, yank, replace- zero. window-edges, split- zero. marker, text-propert,  zero.

So:

- The engine is not  that layer has no buffer implementation at all; it calls down through impl/* into the very engine we've been hardening. Markers, undo, read-only, the CDF, text properties, the corrected line model: ours is the layer beneath it.
- The display and input are not  its layout abstraction (=>winframe-layout, a div tree) has no terminal implementation; that gap is precisely why it "cannot render". What we built is that missing implementation.
- None of this week's features are  isearch, minibuffer completion, the kill ring, undo, prefix arguments, the window geometry and points. That layer doesn't have them.

So the overlap is a shell of ~1,400 lines: windows that know their parent, mode lines that know mode-line-format, a *Messages* buffer, local keymaps, and the backend seam. Nothing else.

One caveat on "just use it"

It's written in the project's lens idiom (=>accessor lenses, buffer-cell, winframe-cell) where we use plain records and set!. So adopting it wholesale means adopting that idiom for the editor  the house style, but a real adaptation, not a drop-in. Stealing the six items into our layering is the cheaper version of the same thing, except the window tree, which is genuinely easier to inherit than to rebuild.

Where that leaves the "alignment"

The realignment is smaller than the last two messages made it sound: promote or steal one shell, keep the engine and the backend and the features. And the thing that's actually  that shell's tests don't load, so its health is  is a pre-existing drift from a lens refactor, not something we did.

Shall I repair that drift and run its tests? That's the one measurement that tells us whether the shell is worth inheriting or worth stealing from.invisible wrong state duplicated duplicated duplicated overlay window match undo ring completion isearch bypass internal windows
why it 
what's there: Per-buffer and per-window local  *default-buffer-local-
what's there: eval-expression / eval-minibuffer (M-:)
why it matters: Present there, absent  and it's the direct bridge into the elisp interpreter.
ours today: nothing
here keymap*,
=>buffer-local-keymap, =>window-local-keymap
why it matters: This is how modes rebind keys. We have one global map plus the minibuffer's. Needed
the moment there's a major mode, or ported text-mode.
ours today: one global map
keymaps matters: In 
what's there: *mode-line-format*, *header-line-format*, 
what's there: messages- Emacs's *Messages*
why it matters: We throw messages away when the echo area clears; they exist only as a transient
string on 
the                    to     frame.
                                                                  ours                                     
status     belongs   part                               today: 
nothing
buffer new-mode-line, new-header-line,             
new-echo-area
why it matters: Emacs's construct language, evaluated per window. Ours is mode-line-string,         
hand-rolled to imitate Emacs's default format. No header line at all.
ours today: hand-rolled string                                                                      
Emacs the tree decides who absorbs the space when a window is deleted. Without it

I wrote a heuristic this week (row band, else column band, else adjacency) and documented it as a   
deviation.
ours today: flat list of windows                                                                    
tree 

-----------------

File format:

What's genuinely misaligned, sized

Our 3,600-line frontend decomposes into:


┌──────────────────────────────────────────────────────────────────┬───────────┬───────────────┐
│                               part                               │ belongs   │    status     │
│                                                                  │    to     │               │
├──────────────────────────────────────────────────────────────────┼───────────┼───────────────┤
│                                                                  │ the       │ fits the      │
│ terminal, rendering, input, key dispatch, command loop           │ backend   │ intended      │
│                                                                  │           │ architecture  │
├──────────────────────────────────────────────────────────────────┼───────────┼───────────────┤
│                                                                  │ the       │ already the   │
│ the engine work (markers, undo, CDF, read-only, line model)      │ C-core    │ intended      │
│                                                                  │ layer     │ lower layer   │
├──────────────────────────────────────────────────────────────────┼───────────┼───────────────┤
│ ~1,500 lines of commands                                         │ the       │ the           │
│ (simple.el/window.el/minibuffer.el/isearch.el/files.el-shaped)   │ editor    │ duplicated    │
│                                                                  │ layer     │ part          │
├──────────────────────────────────────────────────────────────────┼───────────┼───────────────┤
│                                                                  │ behaviour │ valuable,     │
│ ~1,300 lines of frontend tests                                   │  specs    │ would need    │
│                                                                  │           │ re-hosting    │
└──────────────────────────────────────────────────────────────────┴───────────┴───────────────┘

So the misalignment is one layer's worth of commands, not the project. And the durable layers are the two that are already aligned.



--------------

duplication


Direct answer: it's a shell, not a rival. Here's the whole list of what's in there that we don't have.

The six things

what's there: A window tree — window-parent-frame, internal windows
why it matters: In Emacs the tree decides who absorbs the space when a window is deleted. Without it

I wrote a heuristic this week (row band, else column band, else adjacency) and documented it as a
deviation.
ours today: flat list of windows
────────────────────────────────────────
what's there: *mode-line-format*, *header-line-format*, new-mode-line, new-header-line,
new-echo-area
why it matters: Emacs's construct language, evaluated per window. Ours is mode-line-string,
hand-rolled to imitate Emacs's default format. No header line at all.
ours today: hand-rolled string
────────────────────────────────────────
what's there: messages-buffer — Emacs's *Messages*
why it matters: We throw messages away when the echo area clears; they exist only as a transient
Here's the map. The short version: their shell is one file, our shell is one file, and both sit on the same engine.
                                                                                                   Theirs

file: schemacs/apps/emacs.sld
what's in it: 1,463 lines — the whole shell. Buffers, the window tree, frames ("winframes"), mode
lines / header lines / echo area, the minibuffer, keymap + dispatch + self-insert, eval-expression,
 and the impl/* parameters + three view constructors
────────────────────────────────────────
file: schemacs/apps/debugui.sld
what's in it: the debug UI app that renders through it
────────────────────────────────────────
file: schemacs/ui/platform/guile-gi-gtk3.sld, schemacs/backend/guile-gi/gtk3.sld, gtk3-init.sld
what's in it: the GTK backends (attempts)
────────────────────────────────────────
file: schemacs/ui.sld, ui/rectangle.sld, ui/raster*.sld
what's in it: the div/rect layout framework it's built on — the part that doesn't render
────────────────────────────────────────
file: schemacs/editor-tests.scm
what's in it: 146 lines of tests for it — don't load (lens drift), not in the suite
────────────────────────────────────────
file: main-gui.scm
what's in it: its entry point

Worth knowing: it imports (only (schemacs eval) eval-string) — so that layer is already wired to the
Elisp evaluator. That's where eval-expression comes from, and it's the piece that connects the
shell to the interpreter.

Ours

file: schemacs/apps/ncurses-editor.sld
what's in it: 3,471 lines — our shell and our terminal, in one file. The same concerns as theirs
(frames, windows, mode line, echo area, minibuffer, keymap dispatch) plus rendering, cursor
placement and input — which their side never got working
────────────────────────────────────────
file: schemacs/apps/ncurses-editor-tests.scm
what's in it: 1,070 lines of tests for it
────────────────────────────────────────
file: main-ncurses.scm
what's in it: 17-line entry point

Shared — neither side duplicated

┌───────────────────────────────────┬───────────────────────────────────────────────────────────┐
│               file                │                       what's in it                        │
├───────────────────────────────────┼───────────────────────────────────────────────────────────┤
│                                   │ 2,473 lines: the buffer core, CDF, undo, markers, the     │
│ schemacs/editor/engine.sld        │ line model — and run-editor-engine, the bridge between    │
│                                   │ the engine and the impl/* parameters (12 of its 25        │
│                                   │ parameters are still '*TODO*)                             │
├───────────────────────────────────┼───────────────────────────────────────────────────────────┤
│ schemacs/cdf.sld, gap-buffer.sld, │ the engine's substrate (VBAL is the text properties both  │
│  sequence.sld, vbal.sld           │ sides use)                                                │
├───────────────────────────────────┼───────────────────────────────────────────────────────────┤
│ schemacs/keymap.sld,              │ keymaps and commands                                      │
│ editor/command.sld                │                                                           │
├───────────────────────────────────┼───────────────────────────────────────────────────────────┤
│ lens, hash-table, pretty,         │ the platform layer                                        │
│ comparator, weak, vector, …       │                                                           │
└───────────────────────────────────┴───────────────────────────────────────────────────────────┘

The one-sentence consequence

The two lines meet only in engine.sld, so the alignment question is literally what happens to apps/emacs.sld and apps/ncurses-editor.sld — promote one, or merge the six shell pieces from theirs into ours. Everything else (2,473 lines of engine, 1,070 lines of our tests, the terminal work, every feature) sits above or below the seam and carries over either way.

And the one measurement that informs it: repair the lens drift in editor-tests.scm, run it, and find out whether that 1,463-line shell — window tree, mode-line-format, *Messages*, local keymaps, and a working eval-expression — is healthy enough to inherit. Want me to do that now?string on the frame.
ours today: nothing
────────────────────────────────────────
what's there: Per-buffer and per-window local keymaps — *default-buffer-local-keymap*,
=>buffer-local-keymap, =>window-local-keymap
why it matters: This is how modes rebind keys. We have one global map plus the minibuffer's. Needed
the moment there's a major mode, or ported text-mode.
ours today: one global map
────────────────────────────────────────
what's there: eval-expression / eval-minibuffer (M-:)
why it matters: Present there, absent here — and it's the direct bridge into the elisp interpreter.
ours today: nothing
────────────────────────────────────────
what's there: The impl/* parameters + three view constructors
why it matters: The seam that keeps the editor layer independent of the display. We invented our own
seam instead, which is exactly why run-editor-engine sits unfinished.ours today: our own shape
And here's what we did not bypass — which is most of it

I grepped it for everything we've built. isearch — zero. try-completion — zero. kill-ring — zero. undo — zero. kill-line, yank, replace-match — zero. window-edges, split-window — zero. marker, text-propert, overlay — zero.

So:

- The engine is not duplicated — that layer has no buffer implementation at all; it calls down through impl/* into the very engine we've been hardening. Markers, undo, read-only, the CDF, text properties, the corrected line model: ours is the layer beneath it.
- The display and input are not duplicated — its layout abstraction (=>winframe-layout, a div tree) has no terminal implementation; that gap is precisely why it "cannot render". What we built is that missing implementation.
- None of this week's features are duplicated — isearch, minibuffer completion, the kill ring, undo, prefix arguments, the window geometry and points. That layer doesn't have them.

So the overlap is a shell of ~1,400 lines: windows that know their parent, mode lines that know mode-line-format, a *Messages* buffer, local keymaps, and the backend seam. Nothing else.

One caveat on "just use it"

It's written in the project's lens idiom (=>accessor lenses, buffer-cell, winframe-cell) where we use plain records and set!. So adopting it wholesale means adopting that idiom for the editor state — the house style, but a real adaptation, not a drop-in. Stealing the six items into our layering is the cheaper version of the same thing, except the window tree, which is genuinely easier to inherit than to rebuild.

Where that leaves the "alignment"

The realignment is smaller than the last two messages made it sound: promote or steal one shell, keep the engine and the backend and the features. And the thing that's actually wrong — that shell's tests don't load, so its health is invisible — is a pre-existing drift from a lens refactor, not something we did.

Shall I repair that drift and run its tests? That's the one measurement that tells us whether the shell is worth inheriting or worth stealing from.

Here's the map. The short version: their shell is one file, our shell is one file, and both sit on the same engine.
                                                                                                   Theirs

file: schemacs/apps/emacs.sld
what's in it: 1,463 lines — the whole shell. Buffers, the window tree, frames ("winframes"), mode
lines / header lines / echo area, the minibuffer, keymap + dispatch + self-insert, eval-expression,
 and the impl/* parameters + three view constructors
────────────────────────────────────────
file: schemacs/apps/debugui.sld
what's in it: the debug UI app that renders through it
────────────────────────────────────────
file: schemacs/ui/platform/guile-gi-gtk3.sld, schemacs/backend/guile-gi/gtk3.sld, gtk3-init.sld
what's in it: the GTK backends (attempts)
────────────────────────────────────────
file: schemacs/ui.sld, ui/rectangle.sld, ui/raster*.sld
what's in it: the div/rect layout framework it's built on — the part that doesn't render
────────────────────────────────────────
file: schemacs/editor-tests.scm
what's in it: 146 lines of tests for it — don't load (lens drift), not in the suite
────────────────────────────────────────
file: main-gui.scm
what's in it: its entry point

Worth knowing: it imports (only (schemacs eval) eval-string) — so that layer is already wired to the
Elisp evaluator. That's where eval-expression comes from, and it's the piece that connects the
shell to the interpreter.

Ours

file: schemacs/apps/ncurses-editor.sld
what's in it: 3,471 lines — our shell and our terminal, in one file. The same concerns as theirs
(frames, windows, mode line, echo area, minibuffer, keymap dispatch) plus rendering, cursor
placement and input — which their side never got working
────────────────────────────────────────
file: schemacs/apps/ncurses-editor-tests.scm
what's in it: 1,070 lines of tests for it
────────────────────────────────────────
file: main-ncurses.scm
what's in it: 17-line entry point

Shared — neither side duplicated

┌───────────────────────────────────┬───────────────────────────────────────────────────────────┐
│               file                │                       what's in it                        │
├───────────────────────────────────┼───────────────────────────────────────────────────────────┤
│                                   │ 2,473 lines: the buffer core, CDF, undo, markers, the     │
│ schemacs/editor/engine.sld        │ line model — and run-editor-engine, the bridge between    │
│                                   │ the engine and the impl/* parameters (12 of its 25        │
│                                   │ parameters are still '*TODO*)                             │
├───────────────────────────────────┼───────────────────────────────────────────────────────────┤
│ schemacs/cdf.sld, gap-buffer.sld, │ the engine's substrate (VBAL is the text properties both  │
│  sequence.sld, vbal.sld           │ sides use)                                                │
├───────────────────────────────────┼───────────────────────────────────────────────────────────┤
│ schemacs/keymap.sld,              │ keymaps and commands                                      │
│ editor/command.sld                │                                                           │
├───────────────────────────────────┼───────────────────────────────────────────────────────────┤
│ lens, hash-table, pretty,         │ the platform layer                                        │
│ comparator, weak, vector, …       │                                                           │
└───────────────────────────────────┴───────────────────────────────────────────────────────────┘

The one-sentence consequence

The two lines meet only in engine.sld, so the alignment question is literally what happens to apps/emacs.sld and apps/ncurses-editor.sld — promote one, or merge the six shell pieces from theirs into ours. Everything else (2,473 lines of engine, 1,070 lines of our tests, the terminal work, every feature) sits above or below the seam and carries over either way.

And the one measurement that informs it: repair the lens drift in editor-tests.scm, run it, and find out whether that 1,463-line shell — window tree, mode-line-format, *Messages*, local keymaps, and a working eval-expression — is healthy enough to inherit. Want me to do that now?



The mapping, for what we have

┌──────────────────────────────────────────────────────────────────────────┬────────────────────┐
│                                 our code                                 │    Emacs's file    │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ frontend: beginning-of-line, kill-line, kill-region, yank, undo, word    │ simple.el          │
│ motion, newline, delete-char, scroll-up/down                             │                    │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ frontend: split-window-below/right, delete-window, delete-other-windows, │ window.el (+       │
│  other-window, window-point/start/edges, window-body-height, mode-line   │ window.c for the   │
│ rendering                                                                │ state)             │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ frontend: minibuffer, history,                                           │                    │
│ try-completion/all-completions/minibuffer-complete,                      │ minibuffer.el      │
│ read-from-minibuffer, read-file-name                                     │                    │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ frontend: our isearch                                                    │ isearch.el         │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ frontend: find-file, save-buffer, require-final-newline,                 │                    │
│ write-protection, note-file-read-only!, default-directory, file-name-*,  │ files.el           │
│ directory-entries                                                        │                    │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ frontend: command loop, recursive-edit, prefix args, dispatch-key-event, │ keyboard.c         │
│  keyboard-quit                                                           │                    │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ frontend: render!, cursor placement, colours, the terminal               │ xdisp.c / term.c / │
│                                                                          │  dispnew.c         │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ frontend: the frame record                                               │ frame.el / frame.c │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│                                                                          │ marker.c,          │
│ engine: markers (what I just wrote), insert/delete, search, text         │ insdel.c,          │
│ properties                                                               │ search.c,          │
│                                                                          │ textprop.c         │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ (schemacs weak), (schemacs vector)                                       │ nothing — our      │
│                                                                          │ portability shims  │
├──────────────────────────────────────────────────────────────────────────┼────────────────────┤
│ lens, pretty, hash-table, comparator, sequence, lexer, …                 │ nothing — the      │
│                                                                          │ platform layer     │
└──────────────────────────────────────────────────────────────────────────┴────────────────────┘

Worth noting: the engine's function names already mirror the C files — I namedadjust-markers-for-insertion! / adjust-markers-for-deletion! after insdel.c without deciding to, because that's where the behaviour is documented. So the instinct is already working; it just isn't reflected in the layout.

So what's in the wrong place

1. apps/ncurses-editor.sld — the big one. 3,600 lines that hold code for at least five Emacs Lisp files plus three C files plus a terminal backend. Under your rule it splits into simple.sld, 
window.sld, minibuffer.sld, isearch.sld, files.sld (the Lisp side) and a terminal/command-loop sidmirroring keyboard.c/xdisp.c. That's the answer to "should anything be somewhere else?" — mos
the working editor, and the split is worth doing because the file is now too big to hold in one's head, which is a different reason from cross-matching but the same remedy.                   

2. The engine is rightly one library — mirroring has value for cross-matching functionality, and the
engine's functionality is already findable under text-editor-*. If part of it earns a file of its
own it's markers (marker.c is a genuine subsystem, and overlays will be another).                   

3. There is already a second editor layer, and that's the fork. schemacs/apps/emacs.sld — 1,463     lines, written earlier, "cannot render", and not imported by the working editor (only by debugui and the GTK backend). It is already Emacs-shaped in the way you're describing:

- (schemacs apps emacs) — buffers (current-buffer, selected-buffer, messages-buffer, buffer-local keymaps), windows with parents (window-parent-frame, new-window), frames (winframe-*, =>winframe-layout, =>winframe-selected-window), new-minibuffer, and *mode-line-format* / *header-line-format*.

Two of those are things we've been hand-rolling in the frontend this week: the window tree (I noted its absence when delete-window needed a heuristic, because in Emacs the tree decides who absorbs the space) and mode-line-format (our mode line is a hand-rolled imitation of a construct Emacs evaluates). So the mirroring question forces a real decision: does that layer become canonical, with our terminal work becoming the backend it renders through — or does it get superseded, with its good ideas (tree, mode-line-format) stolen into the new layering? Either way it should be decided before the reorganisation, because it decides where simple.sld and window.sld land.

How I'd do it

Incrementally, driven by the next feature — a big-bang reorg is churn with no new capability. Concretely, in order:

1. isearch.sld first, as a probe: our isearch is the most self-contained section (~250 lines), and Emacs has exactly that file. It proves the mechanics.
2. minibuffer.sld with the completion port — which is next anyway, and which is precisely "port minibuffer.el into a file called minibuffer".
3. window.sld when we next touch windows (window configurations, or the tree decision).
4. files.sld when the next file feature comes.
5. simple.sld last, since it's the grab-bag (Emacs's is 23,000 lines of miscellany, so ours will be too — but "where's kill-region? → simple.sld, same as Emacs" is the whole point).

One mechanical caveat, because it's the thing that could bite: our module-level state is make-parameter objects (*current-frame*, *minibuffer*, *kill-buffer*, *prefix-cu*, …). A parameter is a single object, so importing it and calling it works across libraries and set!-style accessors are just exported procedures — the split is a move plus export work, not a redesign. The one genuine design question is who owns the frame state (frame.sld), since the command loop, the renderer and the minibuffer all reach through *current-frame* today.

Want me to do the isearch split as the probe, so we can see how it feels before committing the rest? Or first look properly at apps/emacs.sld and give you a recommendation on the fork — merge or supersede — since that's the decision the rest hangs on.
