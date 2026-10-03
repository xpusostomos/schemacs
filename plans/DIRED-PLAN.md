
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
