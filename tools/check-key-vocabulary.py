#!/usr/bin/env python3
"""Fail if the modifier-list key vocabulary comes back.

GNU Emacs has no key spelled `(ctrl #\\x)`.  A key is a *string* or a *vector
of events* (`keymap.c'), and an event is an integer carrying its own modifier
bits - `C-x` **is** 24 - or a symbol naming a key that is not a character.
A modifier *name* survives in exactly one place: the Lucid event type list
`(control ?x)', which `event-convert-list' (`keyboard.c:7832') consumes, and
which `Fdefine_key' (`keymap.c:1156') and `Flookup_key' (`:1264') normalise a
vector element through on the way in.

Note that `ctrl' is not even that spelling.  `parse_solitary_modifier'
(`keyboard.c:7920') accepts it as a legacy alias beside `control' and `C',
and **no file in Emacs writes it** - `control' is the spelling.

This tree used to keep its keys in an invented `<keymap-index-type>' record
whose printed form was `(ctrl #\\x)', and that is why the vocabulary was never
confined to the one normalisation seam it belongs in: it *was* the key type,
smeared over ~137 sites.  The record is gone and a key is the list of events
Emacs walks.  This script is the check that keeps it gone - the plan for that
work asked for exactly this grep, so that the spelling cannot come back one
call site at a time.

Comments and string literals are stripped before matching, so a comment may
still *name* the old spelling to explain the purge, and several do.  A
finding is code.  (The stripping is careful about `#\\;' and `#\\"' - a
character literal whose name is a semicolon or a quote - because a scanner
that trips over those blanks the rest of the file and then reports a clean
file as having problems, which is a mistake already made once here by hand.)

Exit status is 1 if anything is reported.
"""
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The names the keymap rewrite deleted.  A name in this list appearing in
# *code* means something was written the old way again.
FORBIDDEN = [
    # The record itself, and the fields that held a whole chord.
    r"<keymap-index-type>",
    r"\bmod-index\b",
    r"\bnext-index\b",
    # The modifier-name table and its lookups.
    r"\bmod-bit-alist\b",
    r"\bsym-lookup-table-alist\b",
    r"\bsym-lookup-table\b",
    r"\bsym-lookup-hash-func\b",
    r"\bmodifier->integer\b",
    # Readers and writers of the private spelling.
    r"\bkeymap-index->list\b",
    r"\bkeymap-index->expr\b",
    r"\bkeymap-index->ascii\b",
    r"\bkeymap-index-head\b",
    r"\bstring->keymap-index\b",
    # The invented "the character this key names" helper, and the layer
    # constructor that took two callbacks.
    r"\bkeymap-index-to-char\b",
    r"\bnew-self-insert-keymap-layer\b",
    # The modifier-list spelling itself.
    r"\(\s*ctrl\b",
    r"'\s*ctrl\b",
]


def strip(source):
    """SOURCE with comments, block comments and strings blanked out.

    Blanked rather than removed so that line and column numbers survive and
    a finding can be printed against the source line the reader sees.
    """
    out = []
    i, n = 0, len(source)
    in_string = False
    while i < n:
        c = source[i]
        if in_string:
            if c == "\\" and i + 1 < n:
                out.append("  ")
                i += 2
                continue
            if c == '"':
                in_string = False
                out.append('"')
                i += 1
                continue
            out.append(c if c == "\n" else " ")
            i += 1
            continue
        if c == "#" and i + 1 < n and source[i + 1] == "|":
            end = source.find("|#", i + 2)
            end = n if end < 0 else end + 2
            out.append("".join(ch if ch == "\n" else " " for ch in source[i:end]))
            i = end
            continue
        if c == ";":
            end = source.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
            continue
        # A character literal, so that `#\;' does not open a comment and
        # `#\"' does not open a string.
        if c == "#" and i + 1 < n and source[i + 1] == "\\":
            out.append("#\\")
            i += 2
            if i < n and source[i] not in "()[] \n":
                j = i
                while j < n and source[j] not in "()[] \n":
                    j += 1
                out.append(source[i:j])
                i = j
            elif i < n:
                out.append(" ")
                i += 1
            continue
        if c == '"':
            in_string = True
            out.append('"')
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def files():
    """Every Scheme file in the tree, sorted, tests included."""
    pats = [os.path.join(REPO, "schemacs", "**", "*.scm"),
            os.path.join(REPO, "tools", "**", "*.scm")]
    found = []
    for pat in pats:
        found.extend(glob.glob(pat, recursive=True))
    return sorted(set(found))


def main():
    bad = 0
    for path in files():
        with open(path, encoding="utf-8", errors="replace") as fh:
            source = fh.read()
        code = strip(source).splitlines()
        raw = source.splitlines()
        for lineno, line in enumerate(code, 1):
            for pat in FORBIDDEN:
                if re.search(pat, line):
                    here = raw[lineno - 1] if lineno <= len(raw) else ""
                    print("%s:%d: %s" % (
                        os.path.relpath(path, REPO), lineno, here.strip()))
                    bad += 1
                    break
    if bad:
        print()
        print("%d use(s) of the modifier-list key vocabulary. A key is an "
              "*event* - an integer carrying its own modifier bits, or a "
              "symbol - and a modifier name belongs only in the Lucid event "
              "type list `(control ?x)' that `event-convert-list' reads."
              % bad)
        return 1
    print("ok: no modifier-list key vocabulary (%d files checked)" % len(files()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
