#!/usr/bin/env python3
"""Parsing an R7RS import list, and what each import set actually brings in.

Shared by the two clash checkers. It has to be exact: `(only (lib) a b c)'
brings in a, b and c and *not* the rest of lib's exports, so treating a
selective import as "the module is imported" makes a missing name look
present - which is how `set!ncurses-frame-crlf?' went unreported once the
test files stopped importing the frontend and started importing the
libraries directly.
"""
import os
import re
import subprocess

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

R7RS_MODULES = ['(scheme base)', '(scheme char)', '(scheme write)',
                '(scheme file)', '(scheme cxr)', '(scheme case-lambda)',
                '(scheme lazy)', '(scheme inexact)', '(scheme read)',
                '(scheme process-context)', '(scheme load)',
                '(scheme repl)', '(scheme eval)']

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
        # a script - a test file - has a top-level `import' instead, and
        # looking only inside `define-library' finds nothing there, which
        # makes every name in it look unimported.
        if isinstance(f, list) and f and f[0] == 'import':
            return f[1:]
    return []


def lib_exports(lib):
    """What LIB exports, or None if Guile cannot resolve it."""
    expr = ('(catch #t (lambda () (let ((m (resolve-interface (quote %s)))) '
            '(for-each (lambda (p) (display (car p)) (display " ")) '
            '(module-map (lambda (k v) (cons k v)) m)))) (lambda a #f))' % lib)
    out = subprocess.run(
        ['guile', '--no-auto-compile', '--r7rs', '-L', REPO, '-c',
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


