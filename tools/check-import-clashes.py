#!/usr/bin/env python3
"""Report names that two of a library's imports both claim.

R7RS says it is an error for one import set to import a name another already
does, and Guile does not enforce it: it warns ("`X' imported from both A and
B") and lets one of them win, decided by the order the import sets are
written in. So a name can quietly mean something other than what the file
says, and nothing fails.

That has bitten this project three times:

  * `newline`, in the frontend, imported from both `(scheme base)` - Guile's
    exports R7RS's output procedure under that name - and
    `(schemacs editor simple)`, which defines the editing command. The
    command lost, so RET called Scheme's `newline` and inserted nothing.
  * `define-key`, in `editor/isearch.sld`: guile-ncurses exports one, and so
    does `editor/keymap.sld`.
  * `define-key` again, in the frontend, for the same reason.

The fix is never to leave it to order: import one of them under a name that
cannot clash (`(rename ...)`, as `newline-command` is), or narrow the import
to the names actually used, which is what `(only (ncurses curses) ...)` is
for.

    tools/check-import-clashes.py            # every .sld in the tree
    tools/check-import-clashes.py <file>...

Exit status is 1 if anything is reported.
"""
import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def strip_forms(text):
    """Drop comments and strings, keeping the structure."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == ';':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '#':
            m = re.match(r'#\\(?:[a-zA-Z0-9]+|.)', text[i:])
            if m:
                out.append(m.group(0))
                i += m.end()
                continue
        if c == '"':
            i += 1
            while i < n:
                if text[i] == '\\':
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def read_forms(text):
    """The top-level forms of TEXT, as nested lists of tokens."""
    tokens = re.findall(r'\(|\)|[^\s()]+', text)
    stack, forms = [], []
    for t in tokens:
        if t == '(':
            stack.append([])
        elif t == ')':
            if not stack:
                continue
            done = stack.pop()
            (stack[-1] if stack else forms).append(done)
        else:
            (stack[-1] if stack else forms).append(t)
    return forms


def import_block(text):
    """The import sets of a library file.

    The `import' form is inside `define-library', so it is not a top-level
    form of the file; a top-level search finds nothing.
    """
    forms = read_forms(strip_forms(text))
    for f in forms:
        if isinstance(f, list) and f and f[0] == 'define-library':
            for part in f:
                if isinstance(part, list) and part and part[0] == 'import':
                    return part[1:]
    return []


def lib_exports(lib):
    """What LIB exports, or None if Guile cannot resolve it."""
    expr = ('(catch #t (lambda () (let ((m (resolve-interface (quote %s)))) '
            '(for-each (lambda (p) (display (car p)) (display " ")) '
            '(module-map (lambda (k v) (cons k v)) m)))) (lambda a #f))' % lib)
    out = subprocess.run(
        ['guile', '--no-auto-compile', '-L', REPO, '-c',
         '(import (scheme base) (scheme write))\n' + expr],
        capture_output=True, text=True,
        env=dict(os.environ, GUILE_WARN_DEPRECATED='no')).stdout
    return out.split()


def is_lib_name(tokens):
    return all(re.match(r'^[A-Za-z0-9_.+~:@-]+$', t) for t in tokens)


def resolve(import_set, cache):
    """The local names an import set brings in, as {name: how}."""
    if not isinstance(import_set, list) or not import_set:
        return {}
    head = import_set[0]
    if head == 'only':
        inner = resolve(import_set[1], cache)
        return {n: inner.get(n, '?') for n in import_set[2:] if n in inner}
    if head == 'except':
        inner = resolve(import_set[1], cache)
        return {n: v for n, v in inner.items() if n not in import_set[2:]}
    if head == 'prefix':
        inner = resolve(import_set[1], cache)
        pfx = import_set[2]
        return {(pfx + n) if pfx.endswith(':') else (pfx + n): v
                for n, v in inner.items()}
    if head == 'rename':
        inner = resolve(import_set[1], cache)
        out = dict(inner)
        for pair in import_set[2:]:
            if isinstance(pair, list) and len(pair) == 2 and pair[0] in out:
                out[pair[1]] = out.pop(pair[0])
        return out
    if head in ('library', 'name'):
        return resolve(import_set[1], cache)
    # a bare library name
    if is_lib_name(import_set):
        key = ' '.join(import_set)
        if key not in cache:
            cache[key] = lib_exports('(%s)' % key)
        return {n: key for n in cache[key]}
    return {}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    # The libraries, and not the test suites that live beside them: the
    # two were told apart by extension while the libraries were `.sld'.
    paths = args or sorted(p for p in glob.glob(
        os.path.join(REPO, 'schemacs/**/*.scm'), recursive=True)
        if not p.endswith('-tests.scm'))
    cache, reported = {}, 0
    for path in paths:
        text = open(path).read()
        sets = import_block(text)
        if not sets:
            continue
        seen, clashes = {}, []
        for s in sets:
            for name, where in resolve(s, cache).items():
                if name in seen and seen[name] != where:
                    clashes.append((name, seen[name], where))
                else:
                    seen[name] = where
        for name, a, b in sorted(set(clashes)):
            print('%s: `%s\' imported from both (%s) and (%s)'
                  % (os.path.relpath(path, REPO), name, a, b))
            reported += 1
    if reported:
        print()
        print('Import one of them under a name that cannot clash, or narrow '
              'the import with (only ...); whichever one wins today is '
              'decided by the order of the import sets.')
        return 1
    print('ok: no name is imported twice (%d files checked)' % len(paths))
    return 0


if __name__ == '__main__':
    sys.exit(main())
