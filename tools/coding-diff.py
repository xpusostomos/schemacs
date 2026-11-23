#!/usr/bin/env python3
"""Run a corpus of files through GNU Emacs and through schemacs, and compare.

Every check in this work so far has been an ad-hoc probe against Emacs - real,
but one at a time and none of them repeatable. This is the repeatable one: it
puts the same bytes in front of both editors and compares two things per case,

  * the coding system each chose for the file, and
  * the bytes each wrote back after a save,

and it fails on any difference that is not already on the known list.

    python3 tools/coding-diff.py            # report, exit 1 on a *new* diff
    python3 tools/coding-diff.py -v         # list every case, not just diffs

**The known list is the point.** A departure that is understood and named is
recorded in KNOWN_DIFFERENCES with its reason, so it does not drown the run;
and a departure that is *not* there is a regression or a discovery, which is
what the exit code is for.

The Emacs side runs `emacs -Q --batch`, stock, and each editor is given its own
copy of the file so the two round trips cannot interfere.
"""
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# **The shared site directory is on the load path or nothing loads.**
# `(schemacs keyboard)` imports `(scheme-utils repl server)` from
# there, and without `-L` the editor libraries fail to resolve and every
# schemacs answer is `None` (measured - that is what made this tool
# report 19 "NEW" cases against a tree that was fine).
SITE = os.path.join(os.environ.get("XDG_DATA_HOME",
                                   os.path.expanduser("~/.local/share")),
                    "guile", "site", "3.0")
TMP = "/tmp/schemacs-coding-diff"
FIXTURES = "/home/chris/GITE/encoding-test-files"

# --------------------------------------------------------------------
# The corpus.  Each case is a name and the bytes, and between them they
# cover the paths a coding system can be chosen by: a declaration, the
# alist, the BOM, the statistics, and the fallbacks.
# --------------------------------------------------------------------

CASES = {
    # by content: the statistical detector
    "ascii":            b"hello\n",
    "latin1":           b"caf\xe9 na\xefve\n",
    "utf8":             "café\n".encode("utf-8"),
    "utf8-bom":         b"\xef\xbb\xbfhello\n",
    "cjk-utf8":         "中文\n".encode("utf-8"),
    "c1-byte":          b"a\x85b\n",
    "high-byte":        b"a\xe9b\n",
    "nul":              b"a\x00b\n",
    "truncated-utf8":   b"a\xc3(b\n",
    # line endings
    "crlf":             b"one\r\ntwo\r\n",
    "cr-only":          b"one\rtwo\r",
    # by declaration
    "tag-latin1":       b";; -*- coding: latin-1 -*-\n\xe9\n",
    "tag-utf8":         b";; -*- coding: utf-8 -*-\nhello\n",
    "block-coding":     b"hello\nLocal Variables:\ncoding: utf-8\nEnd:\n",
    # UTF-16, with and without a signature
    "utf16-bom":        b"\xff\xfeA\x00B\x00C\x00",
    "utf16-no-bom":     b"A\x00B\x00C\x00",
    # encodings this tree carries, and one it does not
    "shift-jis":        "あい".encode("shift_jis"),
    "big5":             "中文".encode("big5"),
    "iso-2022-jp":      b"\x1b$B$\"$$$&$(\x1b(B\n",
    # by file name: `file-coding-system-alist'
    "name-utf-8":       ("x.utf-8", b"caf\xe9\n"),
    "name-tar":         ("x.tar", b"not really a tar\n"),
}

# --------------------------------------------------------------------
# What is already known to differ, and why.  A case named here is
# reported as expected; anything else is a failure.
# --------------------------------------------------------------------

KNOWN_DIFFERENCES = {
    "iso-2022-jp": (
        "`detect_coding_iso_2022` is not ported (259 lines, a state "
        "machine).  The bytes are safe - they are 7-bit and round-trip - "
        "but the text shows as mojibake."),
}


def run(cmd, timeout=180):
    # **`stdin=DEVNULL` is load-bearing for the Emacs side.** When Emacs
    # cannot encode a buffer it prompts "Select coding system", and in
    # `--batch` that prompt reads stdin: with an inherited stdin it can
    # wait for ever (measured here - a 180 s timeout), where EOF is what
    # makes it error out and leave the file unsaved, which is the answer
    # `ask_emacs`'s third value reports.
    return subprocess.run(cmd, capture_output=True, text=True,
                          timeout=timeout, stdin=subprocess.DEVNULL)


def write_case(name, data):
    """Two copies of the case, one per editor, and the case's name part."""
    if isinstance(data, tuple):
        filename, data = data
    else:
        filename = name + ".txt"
    paths = []
    for editor in ("emacs", "schemacs"):
        path = os.path.join(TMP, "%s-%s" % (editor, filename))
        with open(path, "wb") as port:
            port.write(data)
        paths.append(path)
    return paths[0], paths[1], data


def ask_emacs(path):
    """Emacs's coding system for PATH, the bytes it writes back, and whether
    it managed to save at all.

    **The third value is not decoration.** Emacs refuses to save a buffer
    whose characters its coding system cannot encode - it prompts "Select
    coding system" - and in `--batch` that prompt reads `stdin`, gets EOF,
    and errors out without writing anything. The file is then still the
    *original*, and comparing it to schemacs' answer reads as "Emacs wrote
    N bytes" when Emacs wrote nothing. That is how the `shift-jis` case
    first looked like a schemacs bug.
    """
    elisp = ('(progn (find-file "%s")'
             ' (princ (format "CODING=%%S\\n" buffer-file-coding-system))'
             ' (set-buffer-modified-p t)'
             ' (princ (format "SAVED=%%S\\n"'
             '   (condition-case nil (progn (save-buffer) t) (error nil)))))'
             % path)
    out = run(["emacs", "-Q", "--batch", "--eval", elisp])
    coding = saved = None
    for line in out.stdout.split("\n"):
        if line.startswith("CODING="):
            coding = line[len("CODING="):].strip()
        elif line.startswith("SAVED="):
            saved = line[len("SAVED="):].strip() == "t"
    with open(path, "rb") as port:
        return coding, port.read(), saved


def ask_schemacs(path):
    """schemacs's coding system for PATH, and the bytes it writes back."""
    elisp = """
(import (scheme base) (scheme write) (schemacs files)
        (schemacs frame) (schemacs buffer) (schemacs coding))
(parameterize ((*buffer-list* (list)) (*current-buffer* #f))
  (let* ((ed (find-file-noselect "%s"))
         (frame (new-frame ed 24 80)))
    (display "CODING=") (write (buffer-file-coding-system ed)) (newline)
    (parameterize ((*current-frame* frame) (*current-buffer* ed))
      (set-buffer-modified-p #t)
      (save-buffer))))
""" % path
    script = os.path.join(TMP, "schemacs-side.scm")
    with open(script, "w") as port:
        port.write(elisp)
    out = run(["guile", "--no-auto-compile", "-L", REPO, "-L", SITE,
               "-s", script])
    coding = None
    for line in out.stdout.split("\n"):
        if line.startswith("CODING="):
            coding = line[len("CODING="):].strip()
    with open(path, "rb") as port:
        return coding, port.read()


def main():
    verbose = "-v" in sys.argv or "--verbose" in sys.argv
    os.makedirs(TMP, exist_ok=True)
    # A cold cache, because a stale .go can make a bisect meaningless.
    run(["rm", "-rf", os.path.expanduser("~/.cache/guile/ccache")])

    same, expected, new = [], [], []
    for name, data in CASES.items():
        paths = write_case(name, data)
        original = paths[2]
        e_path, s_path = paths[0], paths[1]
        e_coding, e_bytes, e_saved = ask_emacs(e_path)
        s_coding, s_bytes = ask_schemacs(s_path)

        # When Emacs could not save, `e_bytes' is the *input*, so the byte
        # halves are not comparable - but the *coding* halves still are, and
        # for a by-name case that is the whole point of it.
        coding_ok = e_coding == s_coding
        bytes_ok = e_saved and e_bytes == s_bytes
        if coding_ok and (bytes_ok or not e_saved):
            same.append(name)
            if verbose:
                print("ok    %-16s %s%s"
                      % (name, e_coding,
                         "" if e_saved else "  (Emacs could not save)"))
            continue

        detail = []
        if not coding_ok:
            detail.append("coding: emacs %s vs schemacs %s" % (e_coding, s_coding))
        if not bytes_ok:
            detail.append(
                "bytes: emacs %d vs schemacs %d" % (len(e_bytes), len(s_bytes))
                if e_saved else
                "bytes: schemacs %d, Emacs could not save" % len(s_bytes))
        line = "%-16s %s" % (name, "; ".join(detail))
        if name in KNOWN_DIFFERENCES:
            expected.append((name, line))
            print("known %s" % line)
        else:
            new.append((name, line))
            print("NEW   %s" % line)

    print()
    print("%d cases: %d identical, %d known-different, %d NEW"
          % (len(CASES), len(same), len(expected), len(new)))
    for name, _ in expected:
        print("  known: %-16s %s" % (name, KNOWN_DIFFERENCES.get(name, "")))
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main())
