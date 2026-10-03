
Where dired is

lisp/dired.el is 5,655 lines and dired-aux.el 4,085. We have nothing — one comment in files.sld:1230 noting dired-directory isn't ported.

The two structural gaps

1. Subprocess execution — entirely absent. This is the big one, and it's not optional. dired's listing is insert-directory, which on Unix runs insert-directory-program (default "ls", files.el:8187) via call-process with --dired, then parses the //DIRED// offset line. We have no call-process, process-file or start-process anywhere. That brings its own dependencies: shell-file-name, shell-command-switch, coding-system-for-read/-write, make-temp-file, split-string-and-unquote, shell-quote-wildcard-pattern, executable-find.

The alternative is ls-lisp — Emacs's pure-Lisp listing — which needs file-attributes and friends but no subprocess. Either way the file primitives below are needed.

2. cl-lib — absent. dired-aux.el uses cl-find-if, cl-some, cl-callf, cl-member, cl-list, cl-case, cl-assert; dired.el uses cl-pushnew, cl-loop. schemacs/elisp-eval is an interpreter, not that macro library. Either port the handful used or rewrite those call sites.

File-system primitives (C, fileio.c/dired.c) — all missing

Also missing: abbreviate-file-name (the handoff already notes it — no home directory shortening exists), and directory-files-and-attributes.

Buffer and display facilities

- Text properties — we have them (textprop.sld: put-text-property, add-text-properties, get-text-property, next/previous-single-property-change). dired's dired-filename property and its dired-insert-set-properties depend on these, and insert-directory itself sets dired-filename from the //DIRED// offsets.
- Overlays — absent (make-overlay ×1, overlay-put ×1). Light use, but not zero.
- subst-char-in-region — absent (×4; dired uses it for quoting/unquoting names).
- special-mode — absent. dired-mode derives from it.
- save-restriction / widen — absent. dired narrows and widens around subdirectory insertion.
- We do have: read-only-mode, markers, expand-file-name, file-exists-p, file-writable-p, file-name-directory-part, file-name-nondirectory-part, default-directory, find-file, revert-buffer, y-or-n-p, insert-file-contents, insert, delete-region, looking-at, read.

What I'd port first

1. file-attributes + the file-attribute-* accessors — nothing in dired works without it, and ls-lisp is built on it.
2. file-directory-p, file-name-as-directory, file-regular-p, file-symlink-p, file-readable-p, file-executable-p — cheap predicates over file-attributes/stat.
3. directory-files and directory-files-and-attributes — real ones, beside the completion-shaped directory-entries.
4. call-process (with process-file) — the subprocess primitive. This is a genuine engine-level addition, not a file function.
5. The mutating set: make-directory(-internal), delete-file, delete-directory, rename-file, copy-file, file-modes/set-file-modes.
6. special-mode, save-restriction/widen, subst-char-in-region, and cl-lib's handful.

Two things I'd flag before anyone starts: dired.el:42 also (require 'dnd) for mouse drag-and-drop, which is skippable for a first port; and directory-entries being completion-shaped means the existing completion code would need to keep working while a real directory-files is added beside it.

Want me to start on the file-attributes layer, or write this up as a page you can keep alongside GTK-PLAN.md and the other plan files?




Named departures

1. define-derived-mode takes the keymap and hook as arguments rather than deriving CHILD-map/CHILD-hook from the mode's symbol. There's no variable registry here — the same thing xdisp.sld already notes about mode-line-format resolving a symbol to nothing — so a symbol can't be turned back into a variable. The four name helpers are kept, so a mode written with the convention spelled out gets the names Emacs would have given it.
2. Keymap inheritance is layers, not parents. (set-keymap-parent map (current-local-map)) becomes appending the parent's layers to the child's, which is this tree's spelling of the same thing.
3. use-local-map / current-local-map live in buffer.sld, not keymap.sld. They're keymap.c's, but keymap.c cannot see a buffer here: buffer → frame → keymap → buffer is a genuine cycle.
4. kill-all-local-variables has no permanent-local exception (a slot is keyed by a plain value, so there are no variable properties), and its forced mode-line redisplay is a no-op — this editor redraws after every command.
5. run-mode-hooks doesn't call hack-local-variables (no file-local variables yet) or set parse-sexp-lookup-properties.



Checked: apart from the mode machinery, the keymap inheritance and the overlays (all done), nothing dired needs exists yet. Here's the order.

1. dired.sld — the file-attributes layer (start here)

file-attributes and the file-attribute-* accessors, directory-files, directory-files-and-attributes,
file-name-all-completions, file-name-completion. Emacs keeps these in src/dired.c, not fileio.c, so
that's the mirrored name.

Nothing else works without it, and ls-lisp is built entirely on it — I counted what ls-lisp.el
calls: file-attributes, directory-files-and-attributes, directory-files,
file-attribute-{type,modes,size,user-id,group-id,link-number,inode-number}, file-relative-name,
file-name-nondirectory, file-name-as-directory, file-directory-p. That's the whole dependency list.

The work is Emacs's shape, not the syscalls — Guile gives raw stat numbers, and Emacs wants the mode
as a string ("drwxr-xr-x" or t for a dangling symlink), uid/gid as names via getpwuid, times as
(SEC HIGH LOW …) lists, and the link target as element 0.

2. The files.el wrappers ls-lisp wants

file-truename, file-relative-name, file-name-sans-versions, file-name-base, abbreviate-file-name.
Most are pure string work. (The mutating ones — delete-directory, make-directory, delete-file — are
for dired-aux later.)

3. The two small decided items

inhibit-read-only — a buffer-local counter barf-if-buffer-read-only consults. dired writes into a read-only buffer 18 times, and the buffer list currently works around its absence with a comment saying so.                                                                                                 
find-file-name-handler — ~20 lines, plus the same two lines at the top of each primitive we've already read. Register no handlers; the point is that "no remote files" becomes "no handler is registered" rather than "this primitive can't".

4. ls-lisp.sld

The listing itself, on top of step 1. No subprocess, no //DIRED// parsing, no coding systems.

5. insert-directory (files.el)

Emacs dispatches here — ls-lisp on non-Unix, the ls program on Unix. Ours always takes the ls-lisp branch, and that's the one place our dired deliberately differs from Unix Emacs, so it should be named at the definition rather than left to be discovered.

6. dired.sld — the mode

dired-mode derived from special-mode, its keymap and hook, the listing commands, navigation, marking. The bulk.

7. dired-aux.sld

Later and separate — copy, rename, compress, shell-command. It's where async processes would have come in, which ls-lisp avoided for the listing but dired-aux can't avoid entirely for ! and friends.

The one shared thing, already decided

Buffer variables — dired is full of buffer-locals (dired-directory, dired-subdir-alist, dired-marked), and our key-based store handles all of them today. The buffer-var / set-buffer-var! form is about ported code reading like Emacs, not about dired working. So it can go before or after; I'd put it after, since dired will show us what the accessors actually need.

What I'd do next

Steps 1–3 as one pass — the file-attributes layer, the wrappers it needs, and the two small decided items. That's a coherent unit with a testable checkpoint: file-attributes against stat, and ls-lisp's dependency list satisfied.

Then step 4 (ls-lisp) and step 5 are another pass, and dired itself is the one after.


