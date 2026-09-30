#!/usr/bin/env python3
"""Generate `schemacs/editor/characters.sld` from Emacs's characters.el.

`char-width-table` is not something to retype by hand: it is 295 zero-width
ranges and 133 double-width ranges, taken from the Unicode character
database, and a transcription slip in a table like that is invisible until
some buffer draws a character nobody tried. So it is generated - from
GNU Emacs's own `lisp/international/characters.el`, which is where Emacs
fills in the table that `src/character.c` creates empty.

    tools/gen-char-width-table.py /path/to/emacs/lisp/international/characters.el

The Emacs tree is found under $EMACS_SOURCE, or as the first argument.
Emacs ships the file gzipped; this reads either.

Everything outside the two `char-width-table' blocks is ignored: the file
also defines charsets, category sets and `printable-chars', none of which
this editor has yet. The default of 1, and the two 4-wide ranges, are NOT
here - they are C (`syms_of_character' in character.c) and belong to
`character.sld', which is where they are.
"""
import gzip
import os
import re
import sys

DEFAULT_SOURCE = '/usr/share/emacs/31.1/lisp/international/characters.el.gz'

HEADER = '''\
(define-library (schemacs editor characters)
  ;; This library mirrors GNU Emacs's `lisp/international/characters.el'
  ;; - specifically the part of it that fills in `char-width-table', the
  ;; table `src/character.c' creates with a default of 1.
  ;;
  ;; GENERATED - do not edit by hand. See
  ;; `tools/gen-char-width-table.py', which reads Emacs's own
  ;; characters.el and writes this file; the ranges are the Unicode
  ;; East Asian Width and combining-class data that Emacs ships, and
  ;; they are far too many to transcribe without a slip.
  ;;
  ;; The table is a sorted vector of `#(START END WIDTH)' with the ranges
  ;; *disjoint and in order*, so `char-width-range' can bisect it. It is
  ;; bisected rather than scanned because it is consulted once per
  ;; character of every line redisplayed.
  ;;
  ;; `character.sld' is `character.c', which owns `char-width' itself and
  ;; the table's default. The two file names differ by one letter because
  ;; Emacs's do.

  (import (scheme base))

  (export char-width-ranges)

  (begin

    ;; The ranges, sorted by start. A character in none of them is 1
    ;; column wide, which is the table's default.
    (define char-width-ranges
      (vector
'''
FOOTER = '''\
       ))

    ))
'''


def read_source(path):
    if path.endswith('.gz'):
        with gzip.open(path, 'rt', encoding='utf-8', errors='replace') as port:
            return port.read()
    with open(path, encoding='utf-8', errors='replace') as port:
        return port.read()


def extract(text):
    """The `(START END . WIDTH)' ranges of the two char-width-table blocks."""
    i = text.index(';;; Setting char-width-table')
    tail = text[i:]
    blocks = re.findall(
        r"\(let \(\(l '\((.*?)\)\)\)\s*"
        r"\(dolist \(elt l\)\s*"
        r"\(set-char-table-range char-width-table elt (\d)\)\)",
        tail, re.S)
    if len(blocks) != 2:
        raise SystemExit('expected 2 char-width-table blocks, found %d'
                         % len(blocks))
    out = []
    for body, width in blocks:
        width = int(width)
        for lo, hi in re.findall(
                r'\(#x([0-9A-Fa-f]+) \. #x([0-9A-Fa-f]+)\)', body):
            out.append((int(lo, 16), int(hi, 16), width))
    return out


def merge(ranges):
    """Sorted, disjoint ranges - a later block wins, as Emacs's last set does."""
    width_of = {}
    for lo, hi, w in ranges:
        for c in range(lo, hi + 1):
            width_of[c] = w
    out = []
    for c in sorted(width_of):
        w = width_of[c]
        if out and out[-1][1] == c - 1 and out[-1][2] == w:
            out[-1][1] = c
        else:
            out.append([c, c, w])
    return out


def main():
    path = (sys.argv[1] if len(sys.argv) > 1
            else os.environ.get('EMACS_SOURCE', DEFAULT_SOURCE))
    if os.path.isdir(path):
        path = os.path.join(path, 'lisp/international/characters.el')
    if not os.path.exists(path):
        raise SystemExit('no characters.el at %s (pass a path, or set '
                         'EMACS_SOURCE)' % path)
    ranges = merge(extract(read_source(path)))
    out = [HEADER]
    for lo, hi, w in ranges:
        out.append('        #(#x%04X #x%04X %d)\n' % (lo, hi, w))
    out.append(FOOTER)
    sys.stdout.write(''.join(out))


if __name__ == '__main__':
    main()
