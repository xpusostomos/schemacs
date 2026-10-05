#!/usr/bin/env python3
"""Report names a library uses but does not import.

This is the general form of a bug that has now cost four round trips in this
project, each time reporting as an unbound variable the first time the code
ran, never at load:

  * `display', in `editor/disp-table.sld' - `(scheme write)', not
    `(scheme base)'. Every unit test passed; the editor died on its first
    redisplay, in a terminal.
  * `string-prefix?', in `editor/minibuffer.sld' - Guile's, not R7RS's.
    Seven completion tests caught it.
  * `display' and `write-char', in `editor/xdisp.sld' - `(scheme write)',
    not `(scheme base)'. The same mistake as `disp-table.sld' two hundred
    lines of code later, which is why this check exists.
  * `call-with-input-file' and `call-with-output-file', in
    `editor/files.sld' - `(scheme file)'.
  * `new-text-editor' and a dozen more, in `editor/files.sld' - names the
    moved code used that the library's import list predated.

The check is: for every name the library's body mentions, is it defined
here, or exported by one of the libraries that exist, or in an R7RS module,
or a `(guile)' name, or a local? A name that is *none* of those is either a
missing import or a local the crude text scan could not see - which is why
this reports rather than fails, and why the report is short enough to read.

    tools/check-missing-imports.py                # every .sld in the tree
    tools/check-missing-imports.py <file>...

Exit status is 1 if anything is reported.
"""
import glob
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import import_sets

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

EDITOR_LIBS = [
    '(schemacs editor engine)', '(schemacs editor frame)',
    '(schemacs editor command)', '(schemacs editor keymap)',
    '(schemacs editor keyboard)', '(schemacs editor minibuffer)',
    '(schemacs editor simple)', '(schemacs editor window)',
    '(schemacs editor isearch)', '(schemacs editor xdisp)',
    '(schemacs editor disp-table)', '(schemacs editor files)',
    '(schemacs keymap)', '(schemacs lens)',
    '(schemacs vector)', '(schemacs string)', '(schemacs bitwise)',
    '(schemacs comparator)', '(schemacs hash-table)', '(schemacs pretty)',
    '(schemacs lexer)', '(schemacs bit-stack)', '(schemacs cursor)',
    '(schemacs elisp-eval)', '(schemacs elisp-load)',
    '(schemacs ui platform ncurses)', '(schemacs ui text-buffer-impl)',
]
R7RS_MODULES = ['(scheme base)', '(scheme char)', '(scheme write)',
                '(scheme file)', '(scheme cxr)', '(scheme case-lambda)',
                '(scheme lazy)', '(scheme inexact)', '(scheme read)',
                '(scheme process-context)', '(scheme load)',
                '(scheme repl)', '(scheme eval)']
def exports(lib):
    """What LIB exports, through the one reader that works.

    The local copy of this used to pass `--r7rs' only for the `(scheme ...)'
    modules, and without it the lookup returned nothing at all - so `known'
    was almost empty, no name ever matched a library, and the check reported
    clean on a file with a real missing import.
    """
    return import_sets.lib_exports(lib)


def body_of(src):
    return src[src.index('\n  (begin'):] if '\n  (begin' in src else src


def exported_names(src):
    """The names a library's `(export ...)' declares.

    This file defines them, whatever the body scan can see: a record type's
    accessors and a lens's generated names never appear as `(define ...)',
    and without this every one of them reads as a name the file forgot to
    import.
    """
    start = src.find('(export')
    if start < 0:
        return set()
    depth, i = 0, start
    while i < len(src):
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                break
        i += 1
    return set(TOKEN.findall(strip_text(src[start:i + 1])))


def imports_of(src):
    """The import form, matched by parens.

    A `.sld' has `(export' after it to cut at, but a script (a test file)
    does not, and cutting on `(export' there leaves nothing - which turned
    every whole-module import in the test files into a false positive.
    """
    start = src.find('(import')
    if start < 0:
        return ''
    depth, i = 0, start
    while i < len(src):
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                return src[start:i + 1]
        i += 1
    return src[start:]


def strip_text(text):
    out = []
    for l in text.split('\n'):
        o, i, n = [], 0, len(l)
        while i < n:
            if l[i] == ';':
                break
            if l[i] == '"':
                i += 1
                while i < n and l[i] != '"':
                    if l[i] == '\\':
                        i += 1
                    i += 1
                i += 1
                continue
            o.append(l[i])
            i += 1
        out.append(''.join(o))
    return '\n'.join(out)


DEFRE = re.compile(
    r'^[ ]*\(define(?:-record-type|-syntax|-values|-constant|-parameter)?\s+\(?([^\s()]+)')
TOKEN = re.compile(r"[^\s()\[\]',;`]+")

# R7RS syntax is not always in Guile's export lists (a macro need not appear
# in `module-map'), so these are named here rather than asked for.
SYNTAX = set("""and begin case cond define define-record-type define-syntax
 define-values do else guard if lambda let let* let*-values let-values letrec
 letrec* or parameterize quasiquote quote set! syntax-rules unless unquote
 unquote-splicing when include include-ci cond-expand""".split())


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    paths = args or sorted(glob.glob(
        os.path.join(REPO, 'schemacs/**/*.sld'), recursive=True))

    known, guile = {}, set()
    for lib in EDITOR_LIBS:
        named = exports(lib)
        if named:
            known[lib] = named
    for mod in R7RS_MODULES:
        known[mod] = exports(mod)
    guile = exports('(guile)')
    if not known:
        sys.exit('could not read the export lists from guile')

    reported = 0
    cache = {}
    for path in paths:
        src = open(path).read()
        body = strip_text(body_of(src))
        # What this file actually brings in. A selective import
        # `(only (lib) a b c)' provides a, b and c and nothing else, so the
        # import sets have to be resolved rather than matched as text - the
        # text match is what let `set!ncurses-frame-crlf?' go unreported.
        available = set()
        for import_set in import_sets.import_block(src):
            available |= set(import_sets.resolve(import_set, cache))
        defined = {m.group(1) for m in (DEFRE.match(l) for l in body.split('\n')) if m}
        defined |= exported_names(src)
        missing = {}
        for name in sorted(set(TOKEN.findall(body))):
            if name in defined or name in available or name in SYNTAX:
                continue
            hit = [lib for lib, names in known.items() if name in names]
            if hit:
                missing[name] = hit[0]
            elif name in guile:
                # Guile has it, but a library has to import it: `display'
                # is Guile's and not `(scheme base)'s, and `disp-table.sld'
                # did not see it until a terminal ran the renderer.
                missing[name] = '(guile)'
        if missing:
            reported += 1
            print('%s:' % os.path.relpath(path, REPO))
            by_lib = {}
            for name, lib in sorted(missing.items()):
                by_lib.setdefault(lib, []).append(name)
            for lib, names in sorted(by_lib.items()):
                if lib == '(guile)':
                    print('    (only (guile) %s)' % ' '.join(names))
                else:
                    print('    from %-32s %s' % (lib, ' '.join(names)))
    if reported:
        print()
        print('%d file(s) use a name no import of theirs provides. Some are '
              'locals this crude scan cannot see; the rest are missing '
              'imports, which fail at run time and never at load.'
              % reported)
        return 1
    print('ok: every name used is defined, imported, or a local (%d files)'
          % len(paths))
    return 0


if __name__ == '__main__':
    sys.exit(main())