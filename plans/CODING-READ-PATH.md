# The coding read path: why `find-file` and `detect-coding-region` disagree

The last open question in the file path (`AGENTS.md`, `a66999e`): *why does
`find-file` name a coding system that its own `detect-coding-region` does
not?* — "the read path has a step this reading has not found."

**Found.** It is `CODING_MODE_LAST_BLOCK`, and it is a one-line difference
between the two detectors.

## The two functions

Emacs has the detection logic **twice**:

| function | called by | sets `CODING_MODE_LAST_BLOCK`? |
|---|---|---|
| `detect_coding` (`coding.c:6501`) | `decode_coding_gap` (`:7926`) → `insert-file-contents` (`fileio.c:5114`) | **no** |
| `detect_coding_system` (`coding.c:8686`) | `detect-coding-region` (`:9027`), `detect-coding-string` (`:9053`) | **yes** (`:8712`) |

`find-file` decodes through `decode_coding_gap`, so it uses the first.

## The mechanism

`detect_coding_utf_8` reads a lead byte and then up to four continuation
octets through `ONE_MORE_BYTE` (`coding.c:633`), which **jumps to
`no_more_source` when the source runs out**:

```c
 no_more_source:
  if (src_base < src && coding->mode & CODING_MODE_LAST_BLOCK)
    {
      detect_info->rejected |= CATEGORY_MASK_UTF_8;
      return 0;
    }
  ...
  detect_info->found |= CATEGORY_MASK_UTF_8_AUTO | CATEGORY_MASK_UTF_8_NOSIG;
  return 1;                       /* NOT rejected */
```

So a scan that runs out of bytes *in the middle of a sequence* is:

- **rejected**, when the input is the last block (`detect-coding-region`);
- **inconclusive — not rejected**, when it is not (`insert-file-contents`).

And "not rejected" is enough, because when nothing is *found* the fallback
takes **the first priority that was not rejected** (`detect_coding`,
`:6684`), and `utf-8` is high in the priority list.

## The evidence

`a1` repeated N times — a byte that is never valid as a UTF-8 lead:

| bytes | `insert-file-contents` | `detect-coding-region … t` |
|---|---|---|
| 2, 3, **4** | **utf-8** | iso-latin-1 |
| **5**, 200 | iso-latin-1 | iso-latin-1 |

and the five-byte edge falls straight out of the scan: the loop tries a
lead byte plus up to four continuation octets. At N ≤ 4 the source ends
mid-probe → `no_more_source` → not rejected → `utf-8` wins the fallback.
At N ≥ 5 the probe **completes** and falls out of the loop, hitting the
unconditional

```c
  detect_info->rejected |= CATEGORY_MASK_UTF_8;
  return 0;
```

which is not conditioned on anything — so `utf-8` is rejected and the
fallback takes the next priority, `iso-latin-1`.

The original three-byte case (`2d 4e 87`) is the same shape, and so is
`a1 a1`.

## Ruled out along the way

- **the eol** — not involved;
- **`prefer-utf-8`** — `detect-coding-region` passes `Qnil`, which becomes
  `Qundecided` by the same `NILP` test (`:8700`), so both see the same value;
- **the file name** — `.qzx`, `.bin` and `.txt` all answer the same, and
  `find-operation-coding-system` returns `(undecided)` for each;
- **`highest` alone** — `(detect-coding-region (point-min) (point-max) t)`
  still says `raw-text`/`iso-latin-1` where `find-file` says `utf-8`. It is
  a real difference in the *fallback* (`:8839` vs `:8858`), but not the one
  at work here;
- **`coding->id = this->id`** (`:6625`), the one structural difference
  between the two detectors that the earlier recon flagged. It is a real
  difference; it is not this one.

## What the port should do

`schemacs/editor/coding.scm` ports `detect_coding_system` (the region
function), and `files.scm`'s `coding-system-for-file` uses it. That is
right for every file of five bytes or more and wrong for the small ones —
and it is wrong in Emacs's direction, i.e. it is *not* the same departure
the tree usually has.

Reproducing the read path needs a `detect-coding` variant that differs from
the region one in exactly two ways:

1. **the truncation rule** — a sequence cut off by the end of the input is
   inconclusive, not invalid (`LAST_BLOCK` unset); and
2. **the selection** — the "first priority not rejected" fallback and a
   single coding system rather than a candidate list (the `highest` shape).

Both are small and local to the detector; neither needs the charset
registry or `iso-2022`. `detect_coding` also records the eol as it scans
(`coding->eol_seen`), which this tree gets from `detect-eol` instead —
equivalent for a whole file.

**Not to do**: translate `detect_coding` from reading alone without
reproducing `LAST_BLOCK`, which is what would have happened if this had
been written from the earlier recon. The flag is invisible in the shape of
the function and shows up only as the five-byte edge.

## Implemented (2026-10-13)

`schemacs/editor/coding.scm` now carries the flag, and the file layer asks
the read-path question.

- **`detect-coding-utf-8` is rewritten to the C's scan** (`coding.c:1130`),
  octet by octet: read the lead, read the next octet, require `10xxxxxx`,
  and only *then* test which length the lead opened. The old version
  classified the lead first (`%utf-8-sequence-length`), which cannot
  express the rule - it rejects `a1 a1` outright, where Emacs consumes it
  as a lead plus one octet and then runs out.
- **`no-more-source` is a named local**, the C's label: running out
  *between* characters is not a bad sequence; running out *inside* one is
  a rejection **only in the last block**. Both are in the C's own
  `src_base < src` test.
- **sjis, big5** take the same rule at their truncation clause; **utf-16**
  conditions its odd-count test on the flag; **charset** takes the
  parameter and does not use it (it is not one of the C's four).
- **Two doors**: `detect-coding-system` is the public region function, the
  last block. `detect-coding-bytes` - the name the file layer already
  called - is now the read path (`%detect-coding-system bytes highest #f`),
  which is GNU Emacs's `detect_coding`. `files.scm` needed no change.

### Verified

Against `find-file` on 27 crafted files, **24 agree**. The three that do
not are all accounted for:

- `41 9f 42` - Emacs says `emacs-mule-unix`, we say `japanese-shift-jis-unix`.
  The named, pre-existing departure: `emacs-mule` has no iconv codec.
- `ef bb bf 41` - Emacs says `utf-8-with-signature-unix`. The BOM is a
  *declaration*: `set-auto-coding` names it before the detector is asked.
  Not a detector case at all.
- `61 62` (pure ASCII, **no line break**) - Emacs records `utf-8-unix`, we
  say `undecided`. See below.

The four originally-pinned cases now match: `2d 4e 87`, `a1 a1` and
`a1`×4 are `utf-8-unix` to both, `a1`×5 is `iso-latin-1-unix` to both. And
`detect-coding-system` still answers `raw-text`/`iso-latin-1` for them,
which is what `detect-coding-region` answers in Emacs.

### A further edge, found while verifying: the file with no line break

```
61 62           find-file -> utf-8-unix        last-coding-system-used = utf-8
61 62 0a        find-file -> undecided-unix    last-coding-system-used = utf-8
```

The *decoding* is utf-8 either way; what differs is the name the buffer
records, and it turns on whether there was a line break to settle the eol
with. This is **not the detector** - `detect-coding-region` answers
`(undecided)` for both, and so does `detect-coding-bytes` - it is what the
file layer does with an `undecided` base afterwards. Not chased; recorded
because `coding-tests.scm`'s "a file that declares nothing and is 7-bit is
undecided" asserts `undecided` for the no-newline `abc`, and Emacs's file
path says `utf-8-unix` there.

### Tests

All 41 suites pass. One expectation changed: the case at `coding-tests.scm`
that asserted `raw-text-unix` for `2d 4e 87` **was pinning the departure**
and now asserts both doors - `utf-8-unix` for the read path, `raw-text`
for the region. It is renamed to say what it pins.
