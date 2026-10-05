I checked, and the premise is wrong — **his engine was used, and almost all of it is still there.** The numbers:

```
file                                main    now     diff
schemacs/gap-buffer.sld             638     638     untouched    move to insdel, reshape like emacs
schemacs/sequence.sld               603     603     untouched    throw
schemacs/ui/text-buffer-impl.sld    347     347     untouched    mostly dead, throw with cdf
schemacs/editor/cdf.sld             272     280     +8,  −0      throw
schemacs/weak.sld                  ~       +198,   −0            throw
schemacs/editor/engine.sld         1253    2636    +1566, −182   reshape
```

Of the original `engine.sld`'s 1,167 non-blank lines, **1,028 (88%) are still present verbatim.** At the function level: the original had 54 definitions, there are 104 now, and **exactly one original function is gone** — `text-editor-line-editor-unfreeze` — with 51 added on top.

So what actually happened is the engine was **extended**, not replaced. The 51 additions are the Emacs machinery it lacked: `new-marker`/`set-marker!`/`mark-marker`/`adjust-markers-for-insertion!` (buffer.c), the whole undo group (`%undo-record-insertion!`, `%undo-truncate!`, `text-editor-undo-boundary!`), `string-search-forward`/`text-editor-search-forward/backward` (search.c), `text-editor-set-modified!`, `text-editor-set-read-only!`, `text-editor-write-back`, and the line-size refactor (`text-line-inner->string`, `%text-editor-freeze-editor-with`, `text-editor-load-current-line`) that replaced the one removed function.

**Where precisely the used code is:**

| what                                            | where                                                     |
| ----------------------------------------------- | --------------------------------------------------------- |
| the engine                                      | `schemacs/editor/engine.sld` — all 2,636 lines            |
| his text storage (gap buffer)                   | `schemacs/gap-buffer.sld`, imported at `engine.sld:60`    |
| his line index (CDF)                            | `schemacs/editor/cdf.sld`, imported at `engine.sld:32`    |
| his sequence indirection                        | `schemacs/sequence.sld`, `engine.sld:42`                  |
| his weak tables                                 | `schemacs/weak.sld`, `engine.sld:30`                      |
| his property lists (vbal)                       | `engine.sld:26`                                           |
| his buffer interface + `text-location`          | `schemacs/ui/text-buffer-impl.sld`, `engine.sld:36,37`    |
| and three more live importers of that interface | `editfns.sld:77`, `tabulated-list.sld:36`, `xdisp.sld:44` |

Everything in the editor's buffer/marker/search/undo behaviour ultimately sits on `gap-buffer.sld` and `cdf.sld`, which are his, byte for byte.

**What *wasn't* used is the layer above the engine**, and that's the part I described in the last message: `(schemacs ui)`'s div tree (2,832 lines), `(schemacs apps emacs)` (1,463), `debugui` (660), and the guile-gi backend (~2,800). Not because it was superseded out of laziness — it's a different architecture for the *display*, and the tree that grew here is per-Emacs-file (`window.sld`, `xdisp.sld`, `dispnew.sld`, `term.sld`, `pgtk.sld`) with Emacs's own window/redisplay model rather than a DOM.

**One thing worth flagging as dead weight**, because it looks like "his engine kept" but isn't: `engine.sld:2603`, exported at `:172`:

```scheme
(define (run-editor-engine proc . args)
  (parameterize ((impl/new-buffer*        new-text-editor)
                 (impl/buffer-type?*      text-editor-type?)
                 ...
                 (impl/copy-string*       '*TODO*)
                 (impl/delete-range*      '*TODO*)
                 ... )
    (apply proc args)))
```

That's a bridge that makes his abstract `text-buffer-impl` interface answer with the *new* engine's functions, so his own appI checked, and the premise is wrong — **his engine was used, and almost all of it is still there.** The numbers:

```
file                                main    now     diff
schemacs/gap-buffer.sld             638     638     untouched
schemacs/sequence.sld               603     603     untouched
schemacs/ui/text-buffer-impl.sld    347     347     untouched
schemacs/editor/cdf.sld             272     280     +8,  −0
schemacs/weak.sld                  ~       +198,   −0
schemacs/editor/engine.sld         1253    2636    +1566, −182
```

Of the original `engine.sld`'s 1,167 non-blank lines, **1,028 (88%) are still present verbatim.** At the function level: the original had 54 definitions, there are 104 now, and **exactly one original function is gone** — `text-editor-line-editor-unfreeze` — with 51 added on top.

So what actually happened is the engine was **extended**, not replaced. The 51 additions are the Emacs machinery it lacked: `new-marker`/`set-marker!`/`mark-marker`/`adjust-markers-for-insertion!` (buffer.c), the whole undo group (`%undo-record-insertion!`, `%undo-truncate!`, `text-editor-undo-boundary!`), `string-search-forward`/`text-editor-search-forward/backward` (search.c), `text-editor-set-modified!`, `text-editor-set-read-only!`, `text-editor-write-back`, and the line-size refactor (`text-line-inner->string`, `%text-editor-freeze-editor-with`, `text-editor-load-current-line`) that replaced the one removed function.

**Where precisely the used code is:**

| what                                            | where                                                     |
| ----------------------------------------------- | --------------------------------------------------------- |
| the engine                                      | `schemacs/editor/engine.sld` — all 2,636 lines            |
| his text storage (gap buffer)                   | `schemacs/gap-buffer.sld`, imported at `engine.sld:60`    |
| his line index (CDF)                            | `schemacs/editor/cdf.sld`, imported at `engine.sld:32`    |
| his sequence indirection                        | `schemacs/sequence.sld`, `engine.sld:42`                  |
| his weak tables                                 | `schemacs/weak.sld`, `engine.sld:30`                      |
| his property lists (vbal)                       | `engine.sld:26`                                           |
| his buffer interface + `text-location`          | `schemacs/ui/text-buffer-impl.sld`, `engine.sld:36,37`    |
| and three more live importers of that interface | `editfns.sld:77`, `tabulated-list.sld:36`, `xdisp.sld:44` |

Everything in the editor's buffer/marker/search/undo behaviour ultimately sits on `gap-buffer.sld` and `cdf.sld`, which are his, byte for byte.

**What *wasn't* used is the layer above the engine**, and that's the part I described in the last message: `(schemacs ui)`'s div tree (2,832 lines), `(schemacs apps emacs)` (1,463), `debugui` (660), and the guile-gi backend (~2,800). Not because it was superseded out of laziness — it's a different architecture for the *display*, and the tree that grew here is per-Emacs-file (`window.sld`, `xdisp.sld`, `dispnew.sld`, `term.sld`, `pgtk.sld`) with Emacs's own window/redisplay model rather than a DOM.

**One thing worth flagging as dead weight**, because it looks like "his engine kept" but isn't: `engine.sld:2603`, exported at `:172`:

```scheme
(define (run-editor-engine proc . args)
  (parameterize ((impl/new-buffer*        new-text-editor)
                 (impl/buffer-type?*      text-editor-type?)
                 ...
                 (impl/copy-string*       '*TODO*)
                 (impl/delete-range*      '*TODO*)
                 ... )
    (apply proc args)))
```

That's a bridge that makes his abstract `text-buffer-impl` interface answer with the *new* engine's functions, so his own app could run on it. Seven of its slots are literals `'*TODO*`, and it is **called from nowhere in the tree**. It's the last remnant of the old stack being kept alive, and it's dead code. could run on it. Seven of its slots are literals `'*TODO*`, and it is **called from nowhere in the tree**. It's the last remnant of the old stack being kept alive, and it's dead code.




---

I checked, and the premise is wrong — **his engine was used, and almost all of it is still there.** The numbers:

```
file                                main    now     diff
schemacs/gap-buffer.sld             638     638     untouched
schemacs/sequence.sld               603     603     untouched
schemacs/ui/text-buffer-impl.sld    347     347     untouched
schemacs/editor/cdf.sld             272     280     +8,  −0
schemacs/weak.sld                  ~       +198,   −0
schemacs/editor/engine.sld         1253    2636    +1566, −182
```

Of the original `engine.sld`'s 1,167 non-blank lines, **1,028 (88%) are still present verbatim.** At the function level: the original had 54 definitions, there are 104 now, and **exactly one original function is gone** — `text-editor-line-editor-unfreeze` — with 51 added on top.

So what actually happened is the engine was **extended**, not replaced. The 51 additions are the Emacs machinery it lacked: `new-marker`/`set-marker!`/`mark-marker`/`adjust-markers-for-insertion!` (buffer.c), the whole undo group (`%undo-record-insertion!`, `%undo-truncate!`, `text-editor-undo-boundary!`), `string-search-forward`/`text-editor-search-forward/backward` (search.c), `text-editor-set-modified!`, `text-editor-set-read-only!`, `text-editor-write-back`, and the line-size refactor (`text-line-inner->string`, `%text-editor-freeze-editor-with`, `text-editor-load-current-line`) that replaced the one removed function.

**Where precisely the used code is:**

| what                                            | where                                                     |
| ----------------------------------------------- | --------------------------------------------------------- |
| the engine                                      | `schemacs/editor/engine.sld` — all 2,636 lines            |
| his text storage (gap buffer)                   | `schemacs/gap-buffer.sld`, imported at `engine.sld:60`    |
| his line index (CDF)                            | `schemacs/editor/cdf.sld`, imported at `engine.sld:32`    |
| his sequence indirection                        | `schemacs/sequence.sld`, `engine.sld:42`                  |
| his weak tables                                 | `schemacs/weak.sld`, `engine.sld:30`                      |
| his property lists (vbal)                       | `engine.sld:26`                                           |
| his buffer interface + `text-location`          | `schemacs/ui/text-buffer-impl.sld`, `engine.sld:36,37`    |
| and three more live importers of that interface | `editfns.sld:77`, `tabulated-list.sld:36`, `xdisp.sld:44` |

Everything in the editor's buffer/marker/search/undo behaviour ultimately sits on `gap-buffer.sld` and `cdf.sld`, which are his, byte for byte.

**What *wasn't* used is the layer above the engine**, and that's the part I described in the last message: `(schemacs ui)`'s div tree (2,832 lines), `(schemacs apps emacs)` (1,463), `debugui` (660), and the guile-gi backend (~2,800). Not because it was superseded out of laziness — it's a different architecture for the *display*, and the tree that grew here is per-Emacs-file (`window.sld`, `xdisp.sld`, `dispnew.sld`, `term.sld`, `pgtk.sld`) with Emacs's own window/redisplay model rather than a DOM.

**One thing worth flagging as dead weight**, because it looks like "his engine kept" but isn't: `engine.sld:2603`, exported at `:172`:

```scheme
(define (run-editor-engine proc . args)
  (parameterize ((impl/new-buffer*        new-text-editor)
                 (impl/buffer-type?*      text-editor-type?)
                 ...
                 (impl/copy-string*       '*TODO*)
                 (impl/delete-range*      '*TODO*)
                 ... )
    (apply proc args)))
```

That's a bridge that makes his abstract `text-buffer-impl` interface answer with the *new* engine's functions, so his own app could run on it. Seven of its slots are literals `'*TODO*`, and it is **called from nowhere in the tree**. It's the last remnant of the old stack being kept alive, and it's dead code.


Mostly yes — and I checked it rather than agreeing, so here's exactly where it holds and where it doesn't.

**It holds: the live tree funnels into three entries.**

```
text-editor-insert            ← typing, insert, both file readers, insert-file-contents, undo replay
text-editor-delete-from-cursor ← every deletion (and the in-place break clear at 2121)
text-editor-write-back         ← reaches set-cursor / load-current-line / index-line-offset
```

I verified by grepping the callers of every committed-line mutator: `force-line-break` is called *only* from inside the line-break state machine (lines 259 and 302), and the two merges *only* from inside the two delete primitives (2108, 2146). So nothing reaches them except through those entries. I also checked both live file readers — `find-file-noselect` and `insert-file-contents` — and both read the file into a **string** and call `text-editor-insert`, not the low-level path.

**Two qualifications, both real:**

**1. There is already a bypass in the file.** `text-editor-insert-from-port-until` (`:2151`) drives the character primitive directly and never calls `text-editor-insert` — so it skips the marker/interval adjustment too. It's reached only via `text-load-port`, and I checked: **nothing in the live tree calls `text-load-port`** — only the dead `text-buffer.sld` / `guile-gi-gtk3.sld` stack does. So it's latent, not active. But it's the proof that the funnel is a *convention* nobody enforces, not a property of the code.

**2. The hoisted rule has to be `min(cursor before, cursor after)`, not "the cursor".** `force-line-break` moves the committed-line cursor *forward* (k → k+1) while the change lands on line k — the line that was split. All four existing sites happen to pass the right value, but a single hoisted call that just read the cursor afterwards would leave the split line's own entry stale. With `min(pre, post)` the rule is uniform, and `cdf-push` becomes a pure optimisation you can delete.

**So, sized:**

|                                                                                    | lines | what it buys                                                                                   |
| ---------------------------------------------------------------------------------- | ----- | ---------------------------------------------------------------------------------------------- |
| add the missing invalidate at 2121                                                 | ~1    | removes the coupling to `write-back`'s invalidate — the *whole* of the remaining direct hazard |
| hoist to the 3 entries with `min(pre,post)`, drop the 4 inner calls and `cdf-push` | ~10   | one rule instead of five transcriptions                                                        |
| debug assertion (verify against a walk after a mutation, raise on mismatch)        | ~10   | turns the convention into something enforced                                                   |

**The honest verdict on "reduce risk": yes, clearly** — and the one-line version (add it at 2121) removes the specific fragile coupling I found, which is the only place where correctness currently depends on a *second* invariant rather than the CDF's own. But "without exception" is the part I'd not sign: after hoisting, the funnel is still a convention, and the bypass at 2151 shows someone can step around it. Only the assertion makes it a fact about the code rather than a habit.

It also does nothing about the two things we discussed separately — the worst-case query time, and the reader-side hazard where `cdf-ref` past the watermark returns `#f` instead of raising. Those aren't choke-point problems.



---------------------

Two corrections to what I said earlier, and then the file list. The main one: **the region cache is not what makes `line-number-at-pos` fast.**

There are **two separate implementations** in GNU Emacs, in two different files, answering two different questions.

**1. `src/xdisp.c` — "which line is this position on" (what I measured)**

|                                                            | line   |
| ---------------------------------------------------------- | ------ |
| `count_lines`                                              | 29892  |
| `display_count_lines`                                      | 29909  |
| `display_count_lines_logically`                            | 25426  |
| `BASE_LINE_NUMBER_VALID_P` (freshness macro)               | 19394  |
| the `%l` mode-line case                                    | ~21500 |
| display-line-numbers path (`it->lnum`, `it->lnum_bytepos`) | ~25550 |

`display_count_lines` is a raw gap-aware scan: `BUFFER_CEILING_OF` gives the contiguous run either side of the gap, then `memchr (cursor, '\n', …)` in a loop. **It never consults the region cache.** Reached from `line-number-at-pos` at `src/fns.c:6688` — sixteen lines that just call `count_lines`. This is the 0.18 ms.

**2. `src/search.c` — `find_newline` and the region cache (a different feature)**

|                                          | line      |
| ---------------------------------------- | --------- |
| `newline_cache_on_off`                   | 602       |
| `find_newline`                           | 675       |
| `region_cache_forward` / `_backward` use | 722 / 850 |
| `know_region_cache` (teaching the cache) | 809, 917  |
| `scan_buffer` (the raw scan beneath)     | —         |

This serves **motion**, not line counting: `forward-line` (`cmds.c:97`), `line-beginning-position` (`editfns.c:700`), `line-end-position` (`editfns.c:755`), and the Lisp `count-lines` (`simple.el:1800`).

**3. `src/region-cache.c`** — 781 lines: `new_region_cache` (131), `invalidate_region_cache` (458), `revalidate_region_cache` (537), `know_region_cache` (665), `region_cache_forward/backward`. Shared by three caches — newline, width-run, bidi-paragraph.

**4. `src/insdel.c`** — `invalidate_buffer_caches` (~2206), called from the modify path, invalidating all three over the edited region. The correctness hook: the direct analogue of `cdf-invalidate!`.

**5. `src/indent.c`** — `current-column` (298), `vertical-motion` (2207), which use the width-run cache.

**So the correction, and it matters for the earlier estimate:** I told you "the walk is ten lines, the region cache is the substantial part". Aimed at the wrong file. For the query we actually care about — line number at a position, which is what the mode line and `C-x =` need — **the only thing that matters is `display_count_lines` in xdisp.c**, and the 781 lines of `region-cache.c` buy nothing there.

Also worth knowing about the size: `display_count_lines` looks like ~100 lines of C, but most of that is byte/char plumbing — it threads a `ptrdiff_t *byte_pos_ptr` and works in byte offsets. **Our engine has no separate byte positions; every position is already a character index.** Strip that and the portable core is genuinely small: walk the lines, add their sizes, stop at the target. Which is exactly the ~10 lines I estimated — it's the *speed* that doesn't port, not the length. Same algorithm, 23× slower in Scheme, because the 0.18 ms is `memchr` in C and Scheme's nearest equivalent measured 4.25 ms on the same buffer.

So: if you ever move to the Emacs strategy, the file to read is **`src/xdisp.c` around 29892-30050**, and the file you can leave alone is the one I pointed at last time.



----

swap out cdf:

Two separate questions, and I want to be explicit that I'm answering them differently.

**Easy to do? Yes.** That part I stand by, and here it is concretely:

- **11 functions in `engine.sld`** — five of them (`write-back`, `force-line-break`, the two merges, and the `cdf-push` half of the split) do nothing *but* CDF bookkeeping, so they'd be deleted outright rather than rewritten.
- **Four functions to rewrite** as walks: `get-cursor`, `index-line-offset`, `get-start-of-line`, `get-end-of-line`.
- **Delete** `cdf.sld` (280 lines) and `cdf-tests.scm` (84). The engine is the only importer — nothing else in the tree touches it.
- The portable core of `display_count_lines` is small, because most of its C bulk is byte/char plumbing we don't need: our positions are already character indices.
- It **removes** an invariant rather than adding one — that's a genuine point in its favour, and it's the cleanest argument for it.

So: a day, bounded, one file.

**But that is not what I concluded, and I'd be letting you walk into it if I nodded here.** The measurements I took argue *against* the swap:

|                         | per query | vs the 1.45 ms whole redisplay              |
| ----------------------- | --------- | ------------------------------------------- |
| CDF typical             | 0.0001 ms | invisible                                   |
| CDF worst               | 9.7 ms    | 6.7× the frame                              |
| Walk (ported to Scheme) | 4.25 ms   | **3× the frame, every query, every redraw** |

The swap takes the *worst* case from 9.7 to 4.25 ms — a 2× improvement on something rare — and the *typical* case from 0.0001 to 4.25 ms — a ~40,000× regression on something that happens after every command. That's not a trade I'd make on these numbers.

And there's the unresolved risk: `attrs-at-buffer-position` is called per drawn character, one branch of it calls `get-cursor`, and if that branch is live with an active region, a walk turns a redisplay into ~1,900 walks per frame. I couldn't measure it — my stub broke first — so it's *unknown*, not safe.

**What I'd actually do, in order:**

1. **Add the missing `cdf-invalidate!` at `engine.sld:2121`.** One line. It removes the only place where correctness depends on a *second* invariant (`write-back` invalidating on `line-changed`) rather than the CDF's own discipline. That's the real defect I found.
2. **Bound the CDF's worst case.** The 9.7 ms is the one number that's genuinely bad, and it's not inherent — it comes from rebuilding all 40,000 prefix sums after an edit near the top. Cap the refill and fall back on the tail, or invalidate from the edit rather than the top where the edit permits. Either keeps the 0.0001 ms typical case and pulls the worst case toward the 4.25 ms walk.
3. **A debug assertion** verifying the CDF against a walk, so any future bypass fails loudly instead of drifting.

If after that you still want the Emacs shape — for fidelity, or because the CDF is a structure Emacs doesn't have and you don't want to own it — then yes, it's a day's work and I'll do it. But I'd want you to choose it knowing it costs 3-4× on every redraw, not thinking the difficulty was the only question.


-------------------


You're right, and I framed that badly — the 38 seconds is a claim about *our* engine with a hypothetical swap, not about Emacs. Here's why Emacs doesn't have the problem, and it's not that its algorithm is faster:

```
src/buffer.h:46      #define PT (current_buffer->pt + 0)
src/buffer.h:611     ptrdiff_t pt;    /* Char position of point in buffer. */
```

**In Emacs, `(point)` is a struct field read.** O(1) — no scan, no index, no cache. Nothing derives it. `insdel.c` maintains it as a side effect of every insert and delete.

**In our engine, point is a derived query:**

```scheme
(define (text-editor-get-cursor ed)          ; engine.sld:2348
  ...
  (+ offset (or (and line-ed (gap-buffer-cursor line-ed)) 0)))
```

`offset` comes from the committed-line cursor and the CDF. So point = line-cursor + line-editor-cursor → a *character offset*, and getting there needs the line index.

**Which means the CDF isn't an optimisation bolted onto the side — it's what makes `(point)` answerable at all** in an engine that stores the cursor as (line index, column) rather than as a character position. That's the thing I'd been missing all thread, and it explains everything downstream: why 8,900 free queries sit in the redisplay unremarked, why the CDF's worst case exists, and why my 38 s number was nonsense as a statement about Emacs.

So the order I proposed was backwards. **The prerequisite for the Emacs strategy isn't porting `display_count_lines` — it's making point a field, as Emacs has it.** Do that and:

- `get-cursor` becomes a slot read; the ~8,900 redisplay calls cost nothing regardless of what answers line/column
- the line index is then needed only for genuine line/column questions — the mode line and `C-x =`, one or two per redisplay
- at which point a walk at ~4.25 ms per query is 4-8 ms on a redraw, which *is* in the "who cares" class you described
- and the CDF's 9.7 ms worst case stops being hidden behind a free query and becomes a visible per-redisplay cost — which is an argument for the swap rather than against it, once the query count is down to one

That also matches the engine's existing shape: `text-editor-char-count` is already a hand-maintained field with exactly this character (and `AGENTS.md` records it being inflated by a line merge). Point-as-a-field is the same idea, and it's the one Emacs chose.

So the honest revision: **the swap is easy, but on its own it's the wrong move, and so is what I proposed in its place.** The actual first step is Emacs's — store the cursor instead of deriving it — and that's a bigger change than the swap, because it touches every edit path the way `insdel.c` adjusts `pt`. After that the line index becomes a genuine choice rather than a load-bearing dependency, and *then* the "irrelevant 4 ms" reasoning holds.


Two answers, and the first is a correction.

**Emacs's point is a single integer — we're the ones storing a structure.**

```
Emacs:   ptrdiff_t pt;                    one stored character position; line/col derived
Ours:    (line cursor, line-editor cursor) two stored coordinates; char offset derived
```

So "Emacs-shaped" means **fewer** coordinates, not more. And that's exactly why the CDF exists: our derived direction needs a line index, Emacs's derived direction needs only a scan.

**Which is the good news for your question:**

```
                        today            with point stored
get-cursor (char pos)   derived, 8900/frame   field read, O(1)   <- the whole payoff
cursor-line/-column     slot read, 24/frame   derived, 1/frame
```

The ~8,900 per-frame calls are `get-cursor`, and they become a memory read. After that the only genuine line/column queries in a redisplay are the mode line's — **one or two per frame** — and *then* a walked query at 4.25 ms is 4-8 ms per redraw, which is the "who cares" class you named. So on speed, you're right.

**On "easy" — no, and I'd rather not let you plan on it.** Three reasons:

1. **It isn't "add a field", it's flipping which direction is stored.** One consequence is concrete: the redisplay currently asks `((= i (text-editor-cursor-line ed))` — a *slot read* — to find the row the cursor is on (`xdisp.sld:164`). With point stored that becomes a derived query, so it has to become a **position comparison** instead: Emacs does `IT_CHARPOS (it) == PT` (`xdisp.c:27614`). That's more Emacs-shaped and it's O(1), but it's a change in the redisplay, not in the cursor.

2. **The field is hand-maintained on every edit path** — the character primitive, both deletes, the line break, both merges. The same five sites that maintain the CDF today would maintain point instead. Same hazard, moved, and `text-editor-char-count` is already that kind of field with a bug on record.

3. **The public interface does survive** — this is the encouraging bit. All 216 `set-cursor` call sites keep taking `(line, column)`; one index query moves inside `set-cursor` instead of being spread across `get-cursor`. So the blast radius is much smaller than "216 sites" sounds.

**And they're not independent — they have to be in that order.** The swap is only safe *because* of the point change: with point derived and the CDF gone, a region-active redisplay makes ~8,900 walked queries and takes ~38 seconds. With point stored, those same calls are free and the swap is a routine choice. So:

- **do point first** → the redisplay stops depending on the index, and the index becomes a genuine either/or
- **then the swap is easy and safe** — and you could equally just leave the CDF in place at that point, because it would no longer be load-bearing

Which is the honest answer to "both together": the payoff you're describing is real, it just arrives after step one, and step one is the bigger of the two.


#SEQUENCES

You're right and I was wrong — Guile has it, in `(ice-9 arrays)`. I should have checked before asserting.

**What Guile gives generically**, over `vector`, `string`, `bytevector` and every SRFI-4 homogeneous vector:

```
array?          #t for all of them
array-ref       ✓        array-set!  ✓      array-length  ✓
array-for-each  ✓ (sums a u32vector → 6)
array->list     ✓ (u32vector → (1 2 3))
```

(One wrinkle: Guile's `array-set!` is `(array-set! array value index)` — value before index, unlike `vector-set!`.)

And the Scheme world at large certainly has it — Racket's `sequence` protocol (`for`, `in-vector`, `in-string`, `sequence-ref`), SRFI-158 generators and accumulators, SRFI-146 mappings, SRFI-113 sets, and SRFI-171 transducers, which **Guile itself ships**. So "nobody thought of it" is plainly false.

**But here's the precise reason `sequence.sld` still exists, and it's one field of ten:**

```
make-array with a fill   →  #(#f #f #f)      a heterogeneous vector
make-array with a prototype → #(u32 u32 u32)  a vector *filled with the symbol*
```

**`make-array` can only produce heterogeneous vectors.** There is no generic way to say "give me an empty `u32vector` of length n". And that's exactly what a gap buffer must do — `gap-buffer.sld` calls `(iface-make-sequence iface)` in three places: creating the store (`:106`), and *growing* it (`:142`), which is how a gap buffer works.

So Guile made **access** generic and left **construction** concrete. The iface's other six operations (`ref`, `set!`, `len`, `foreach`, the predicate, `copy`) could all be delegated to `(ice-9 arrays)` today — it's `make` that has no equivalent, and it's the one the storage depends on.

Which gives a concrete finding I wouldn't have reached without your push: **`sequence.sld` could shrink a lot but can't disappear.** Six of its ten fields map onto `(ice-9 arrays)`; roughly 400 of its 603 lines are the 14 hand-written iface tables re-spelling what `array-ref`/`array-set!`/`array-length`/`array-for-each` already do generically. What survives is `make` — and possibly `list`, since `(array? '(1 2 3))` is `#f`.

The reason nobody standardized that half: generic *construction* needs a type-class-style protocol — "allocate one of the same kind as this" — and R7RS has no mechanism for it. That's the same reason `weak.sld`, `vector.sld` and `hash-table.sld` exist as `cond-expand` shims instead of being one library. In Guile the mechanism does exist, and it's GOOPS — which is what the display layer uses and the storage layer doesn't, for the dispatch-cost reason.



You're right, and my claim was wrong. Nothing is gained at `:823` — the cond has already decided the type, so it could call `make-bytevector`/`make-u16vector`/`make-u32vector` directly and be done. There's no dispatch to do; the type is known right there.

**Where a constructor genuinely has to be *carried* as a value is inside `gap-buffer.sld`**, because that's the code that's generic over element type:

```
gap-buffer.sld:106   ((iface-make-sequence iface) store-size fill)   create
gap-buffer.sld:142   ((iface-make-sequence iface) new-len)           grow
gap-buffer.sld:327   ((iface-make-sequence iface) ...)               compact
```

The gap buffer grows its store without knowing whether it holds records, bytes, u16s or u32s — so it must ask *something* to allocate. That's the real need. But that something is **one procedure**, not a ten-field record: `(new-gap-buffer make-store size)` and growth is `(make-store new-len)`.

And here's the part that makes your point land: **on Guile, every other field of the iface is redundant.** I tested all four the gap buffer uses:

```
iface-sequence-length  →  array-length    ✓ generic
iface-sequence-ref     →  array-ref       ✓ generic
iface-sequence-set!    →  array-set!      ✓ generic
iface-sequence-copy!   →  array-copy!     ✓ generic (u32→u32, vec→vec, string→string)
iface-make-sequence    →  nothing generic
```

So the gap buffer's five iface operations reduce, on Guile, to four generic Guile calls plus one constructor argument. The other five fields of the record (`seq?`, `is-vec`, `->list`, `list->`, and `foreach`) aren't used by the gap buffer at all — `iface-is-vector?` isn't read by *anyone*, and `sequence.sld`'s own 603 lines are mostly re-spelling these four.

**So the honest verdict is the one you're driving at:** the iface isn't a design, it's a portability shim for Schemes that lack generic array access — the same family as `weak.sld`, with a bigger blast radius because `gap-buffer.sld` is the storage everything sits on. On Guile it's ~90% redundant with `(ice-9 arrays)` and the residual is a single constructor argument.

And I should own the error: I told you the generic `make` was "exactly what this is for" because I read `%line-editor-pre-freeze` returning an iface and assumed the indirection was load-bearing. It isn't — the indirection there is just "return the iface for the type I already chose", which a direct call expresses better. I'd checked where `make` was *called*, not whether the call site needed to go through the table.


---------------

`gap-buffer.sld` is the one place where the author's code and Emacs are doing the *same thing* — and the core matches exactly.

**Emacs-shaped: the core, precisely.**

Emacs's buffer **is** a gap buffer. `struct buffer_text` (`buffer.h:105-120`) holds `beg`, `gpt`, `gap_size`, `z`, and the read path is:

```c
/* buffer.h:1382, BUF_FETCH_MULTIBYTE_CHAR */
p = ((pos >= BUF_GPT_BYTE (buf) ? BUF_GAP_SIZE (buf) : 0)
     + pos + BUF_BEG_ADDR (buf) - BEG_BYTE);
```

Ours:

```scheme
;; gap-buffer.sld:418
(cond ((< i cursor) (ref vec i))
      (else (ref vec (+ i (- len weight)))))
```

Identical logic — the conditional gap offset — with our `cursor` = `BUF_GPT`, our `(- len weight)` = `BUF_GAP_SIZE`, our `vec` = `BEG_ADDR`. Same three quantities, same read, same idea. `gap-buffer-move-cursor` is `gap_left`/`gap_right` (copying data across the gap), `gap-buffer-set-cursor` is setting `GPT`, and `new-gap-buffer` allocates with slack the way `make_gap`/`enlarge_buffer_text` do.

**But it mirrors no Emacs file, and it doesn't claim to.** There is no `gap-buffer.c`. Emacs's gap is *inlined* into `struct buffer` with macros, and its operations live in `insdel.c`. And unlike `cdf.sld` — which opens by stating outright "It mirrors no Emacs file" — `gap-buffer.sld` has **no header comment at all**, so a reader finds no statement either way. Given the project's rule that every library mirrors a named file, that's the gap worth closing: one line saying what it is.

**The departures:**

**(a) Growth policy differs in kind.** Ours doubles until it fits:

```scheme
(if (< len request) (loop (* 2 len)) len)
```

Emacs adds a fixed cushion to the request: `nbytes_added = min (nbytes_added + GAP_BYTES_DFL, BUF_BYTES_MAX - current_size)` with `GAP_BYTES_DFL = 2000` (`buffer.h:205`). So **ours can over-allocate up to 2×; Emacs holds about 2000 bytes of slack.** Real difference in memory profile — the same insertion pattern leaves a different footprint.

**(b) Emacs shrinks the gap; ours never does.** `compact_buffer` (`buffer.c:1876-1885`): if the gap exceeds 10% of the buffer or 2000 bytes, shrink it to `clip(GAP_BYTES_MIN=20, Z_BYTE/10, GAP_BYTES_DFL=2000)`. `gap-buffer-grow` has no inverse — a buffer that grew for a big file and then had it all deleted keeps the allocation.

**(c) Emacs is byte-oriented and multibyte-aware.** Every position has a byte twin — `GPT_BYTE`, `BEG_BYTE`, `Z_BYTE` — and the macros index *bytes*, with `BUF_FETCH_MULTIBYTE_CHAR` decoding. Ours is element-indexed with no byte positions at all: the same simplification we found in `display_count_lines`, and for the same reason (Scheme chars, no re-encoding).

**(d) It's element-generic.** Emacs's gap holds bytes of one buffer. Ours is instantiated for `<text-line>` records and for u32 character codes, and would work for anything — because the project needs it as a *reusable* structure. Emacs needs no such generality; it has exactly one buffer.

**(e) Two additions Emacs doesn't have.** `gap-buffer-minimum`/`maximum`, maintained by `gap-buffer-update-min-max`/`insert-min-max` — the lowest and highest element inserted. That's for `%line-editor-pre-freeze`'s compression (pick the narrowest vector for a line's character range). And the sequence-interface field, which is a portability shim rather than a design.

**One naming trap worth knowing.** These two don't test lines at all:

```scheme
(define (gap-buffer-end-of-line? gb) (= (gap-buffer-weight gb) (gap-buffer-cursor gb)))
(define (gap-buffer-start-of-line? gb) (= 0 (gap-buffer-cursor gb)))
```

They test end and start **of the buffer**. The names are apt for the *line editor*, which is a one-line gap buffer — and that's where the engine uses `end-of-line?` (`engine.sld:1071`), so no active bug. But `gap-buffer-start-of-line?` is imported into `engine.sld:62` and never called, and calling either on the *lines* buffer would silently mean "cursor is on the last line" rather than anything about a line.

**Verdict:** the algorithm is a faithful match to `buffer.h`/`insdel.c` — the one place in the author's storage code where you can point at Emacs and say "yes, this is that". What's *not* Emacs is the packaging: no mirrored file, no byte orientedness, no shrinking, a different growth constant, and two additions on top. All of which is defensible — the packaging exists because he wanted a reusable structure rather than one inlined buffer — but only one of the five is a deliberate design choice; the rest read as never having been compared against `insdel.c`.

**No — not one name is shared.** 39 exports against Emacs's gap-level names (`gap_left`, `gap_right`, `make_gap`, `make_gap_1`, `make_gap_larger`, `make_gap_smaller`, `enlarge_buffer_text`, `BUF_GPT`, `BUF_GAP_SIZE`, `BUF_BEG_ADDR`, `BUF_Z_ADDR`, `BUF_BYTE_ADDRESS`, `insert_1_both`, `del_range*`, `replace_range*`, …): **zero in common.**

Which is consistent, and unavoidable — you can only port a name if the function exists. There's no `gap-buffer.c` in Emacs, so there's nothing to name after. But it's worth seeing where the two vocabularies *describe the same thing under different words*, because those are the ones a reader would want matched:

| ours                                  | Emacs (insdel.c / buffer.h)                         | note                                                       |
| ------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------- |
| `gap-buffer-cursor`                   | `BUF_GPT(buf)` — "gap position"                     | same quantity                                              |
| `gap-buffer-free-space`               | `BUF_GAP_SIZE(buf)`                                 | same quantity                                              |
| `gap-buffer-weight`                   | `Z - BEG` — no name; it's an expression             | Emacs has no identifier for it                             |
| `gap-buffer-length`                   | the allocation size; `Z_BYTE - BEG_BYTE + GAP_SIZE` |                                                            |
| `gap-buffer-move-cursor`              | `gap_left` / `gap_right` — **two** functions        | ours is one bidirectional                                  |
| `gap-buffer-grow`                     | `make_gap` / `make_gap_larger`                      | ours never shrinks                                         |
| *(nothing)*                           | `make_gap_smaller`, `compact_buffer`                | no counterpart at all                                      |
| `gap-buffer-ref`                      | `BUF_BYTE_ADDRESS` + `BUF_FETCH_MULTIBYTE_CHAR`     | macro, not a function                                      |
| `gap-buffer-insert-before` / `-after` | `insert_1_both` (insdel.c:891)                      | Emacs's is the editor's real insert; ours is storage-level |

So it's not just different names — the **shapes** differ too, and the vocabulary is a Scheme API rather than a transliteration: predicates with `?`, mutators with `!`, `for-each`/`map` families with `/index` variants, a `*…-function*` parameter, and `ref`/`set!` naming from the sequence layer. Emacs has no analogue of any of those conventions because the gap operations are C functions over `struct buffer`.

**Which is the honest answer to your broader question across this whole thread.** The project's rule — *"each function in emacs should be ported with the same name to the same file"* — is satisfiable and being honoured in `editor/*.sld`, where every function *has* an Emacs counterpart. It simply has nothing to say about the author's five portability/storage libraries (`sequence`, `gap-buffer`, `cdf`, `vector`, `hash-table`), because none of them mirrors a file. There, the names are his own by necessity, and the only fidelity question available is the one we've been asking of each: does the *algorithm* match Emacs where Emacs has one?

- `gap-buffer` — yes, the gap algorithm matches `insdel.c`/`buffer.h` closely
- `cdf` — no, Emacs has no line index at all
- `sequence` — no, and on Guile it's mostly redundant
- `vector`, `hash-table` — same shape as `sequence`

So `gap-buffer` is the one of the five where a name-matching port would even be *possible* — and it's also the one where the algorithm already matches, which is arguably the part that matters more than the spelling.


text-buffer-impl, mostly dead
Yes to both, and more precisely than I'd have put it — with one extra thing I found while checking.

**Mostly dead: yes.** The live exports are `text-location` and its two accessors. The 27 parameter stubs are read only by the dead stack (`apps/emacs.sld`, `debugui.sld`, `guile-gi-gtk3.sld`), by the `ui/text-buffer.sld` wrapper that re-exports them unstared, and by `engine.sld`'s `run-editor-engine` — called from nowhere.

**And what's live *is* the CDF's output type — but it isn't part of the CDF, it's what the CDF exists to produce.** `text-location` is constructed in exactly three places, and the chain says it plainly:

```
engine.sld:2536   %text-editor-get-line-column  ← text-editor-index-line-offset
                                                  ← cdf-fill + cdf-find        ← the CDF
engine.sld:2540   %text-editor-get-line-column  ← text-editor-cursor-line/-column   ← the stored coords
engine.sld:2271   text-editor-cursor-location   ← text-editor-cursor-line-number    ← the stored coords
```

So `text-location` is the **(line, column) pair** — the very thing the CDF computes. Which is the same root cause we identified when you asked about making point a field: **this engine stores the cursor as (line, column); Emacs stores a character position.** The CDF is the converter between the two; `text-location` is the converter's return type. Emacs has neither, because `pt` is a field and both are derived on demand.

**And here's the thing I hadn't noticed.** Two of those three constructors disagree about the convention, for the *same record type*:

```scheme
;; engine.sld:2271 — 0-based
(text-editor-cursor-location ed)
  (make<text-location> (text-editor-cursor-line-number ed)      ; no +1
                       (text-editor-cursor-column-number ed))   ; no +1

;; engine.sld:2536 and :2540 — 1-based
  (make<text-location> (+ 1 line-index) (+ 1 offset))
  (make<text-location> (+ 1 (text-editor-cursor-line ed)) (+ 1 (text-editor-cursor-column ed)))
```

and `text-editor-cursor-line-number` is literally the same expression as `text-editor-cursor-line` (both `(gap-buffer-cursor (text-editor-lines ed))`), so the difference really is just the `+ 1` — and the two accessor pairs are duplicates of each other.

The 0-based one is only read by `show-text-editor` — the record printer, i.e. debug output — so it never reaches a user. But it's the same type, `show-text-location` prints `(text-location 2 1)` with no indication of which convention it's in, and the type has no docstring saying whether line and column are 1- or 0-based. Given we already established that `%c`/`%C` in `xdisp.sld` convert at the boundary by hand, that's three conventions for one quantity in one codebase — Emacs's `current-column` (0), Emacs's `%C` (1), and now a debug printer that quietly picks 0.

So, to your question: **mostly dead, and the live remainder is the visible tip of the `cdf` root cause** — the (line, column) model that Emacs doesn't have and that both the CDF and `text-location` exist to serve.

---

engins reshape:

**Names: zero overlap.** I compared the original's 51 functions against 521 function names extracted from `buffer.c`, `insdel.c`, `marker.c`, `search.c`, `editfns.c` and `fileio.c` — the files `engine.sld` says it mirrors. **Not one matches**, even after normalising case and `-`/`_`.

(My first sanity check on that said three Emacs names were "missing" — that was my grep looking for normalised names in a file of hyphenated ones. The extracted list and the comparison are sound.)

**By function, about six do something Emacs does** — under a different name, and usually a different signature:

| original                        | Emacs                                       |
| ------------------------------- | ------------------------------------------- |
| `text-editor-insert`            | `insert` (`insdel.c`)                       |
| `text-editor-get-cursor`        | `point`                                     |
| `text-editor-to-string`         | `buffer-string` (`editfns.c:1697`)          |
| `text-editor-get-start-of-line` | `line-beginning-position` (`editfns.c:700`) |
| `text-editor-get-end-of-line`   | `line-end-position` (`editfns.c:755`)       |
| `text-editor-insert-from-port`  | `insert-file-contents` (`fileio.c`)         |

**The other ~45 are a line model Emacs doesn't have**, in five families:

- **the line editor** (8): `line-editor-char-range`, `-cursor-to-end!`, `-cursor-to-start!`, `-freeze`, `-freeze-line-after`, `-freeze-part`, `%line-editor-pre-freeze`, `text-editor-line-editor-ref`
- **the line object** (8): `text-line`, `text-line-ref`, `text-line-code-ref`, `text-line-for-each`, `text-line-inner-size`, `text-line-outer-size`, `text-line->string`, `text-editor-text-line-ref`
- **the line-break protocol** (7): `line-break`, `line-break-1-state`, `line-break-2-state`, `line-break-size`, `line-break->string`, `text-editor-set-line-break!`, `text-editor-force-line-break`
- **the (line, column) model** (6): `text-editor-cursor-line`, `-column`, `-line-number`, `-column-number`, `-location`, `%text-editor-get-line-column`
- **the CDF** (3): `text-editor-make-cdf-fill-range`, `-until`, `text-editor-index-line-offset`
- plus `text-editor-add-char-count` (Emacs computes `Z - BEG`; it isn't stored), `run-editor-engine`, and two debug printers

**And the contrast makes the point better than the inventory does.** The 55 functions *added* since the original do carry Emacs names — nine exactly:

```
copy-marker   mark-marker   marker-position   set-marker!
set-marker-insertion-type!   signal-after-change
search-forward   search-backward   insert
```

So the marker family, the search family and the change hooks were ported to the rule. The original 51 were not, and couldn't have been.

**The structural reason, which is the same root as everything else in this thread:** Emacs's engine is **character-oriented** — one gap buffer of bytes, `insert` writes characters, and a "line" is a *range* found by searching for `\n` (`find_newline`). The original engine is **line-oriented** — lines are objects in a gap buffer, the line being edited lives in a separate line editor, and a position is a (line, column) pair. Those aren't ports of Emacs functions because they're functions for a different model.

Which is exactly why the CDF exists and why `text-location` exists: a line-oriented engine must convert between its native (line, column) and character indices, and Emacs has no such conversion to port. `AGENTS.md` records this as a deliberate call — *"engine.sld — buffer.c + insdel.c + marker.c + search.c (pre-existing; ~57% ours by git diff main; Chris decided to leave it whole)"*. The measurement backs the "~57%": 55 added functions carry Emacs's names, 51 original ones carry the line model's.
