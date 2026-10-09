#!/usr/bin/env python3
"""Report definitions that a library cannot export, because the name is imported.

GNU Guile resolves a `(define X ...)' in a library body whose name X is also
exported by one of that library's own imports by keeping the *import*: the
definition is silently lost.  R7RS agrees that defining over an imported
binding is an error, so this is a real constraint and not a Guile quirk to
work around - it just has no diagnostic here, and neither the test suites nor
`tools/syntax-check.scm' can see it.

We hit it with `newline'.  Every one of our editor libraries imports
`(scheme base)', and Guile's `(scheme base)' exports `newline' (R7RS-small
says it should not, but Guile's does), so `(define newline ...)' in
`schemacs/editor/simple.scm' was dropped and the keymap ended up bound to
Scheme's output procedure instead of the editing command.  The suites stayed
green; the editor inserted nothing when RET was pressed.

The fix is R7RS's: export the name by `rename' from a differently-spelled
definition, which is what `newline-command' does.

A file that has *already* done that and wants the plain name as well says so
with `(except ...)', which is what `files.scm' does for `delete-file' (the
`(scheme file)' one takes a single argument, Emacs's takes an optional
TRASH).  An excepted name is not a name the library still imports, so it is
not reported - without that rule this check reported a file whose whole
point was that it had handled the clash.

This script checks every library in the tree against the union of the R7RS
module export lists, which is what any library importing `(scheme base)'
gets.  Exit status is 1 if anything is reported.
"""
import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MODULES = ['(scheme base)', '(scheme char)', '(scheme write)', '(scheme file)',
           '(scheme cxr)', '(scheme case-lambda)', '(scheme lazy)',
           '(scheme inexact)', '(scheme read)', '(scheme process-context)',
           '(scheme load)']

DUMP = '''
(import (scheme base) (scheme write))
(for-each
 (lambda (m)
   (catch #t
     (lambda ()
       (let ((i (resolve-interface m)))
         (display m) (display "\\t")
         (for-each (lambda (p) (display (car p)) (display " "))
                   (module-map (lambda (k v) (cons k v)) i))
         (newline)))
     (lambda (k . a) #f)))
 (list %s))
''' % ' '.join("'%s" % m for m in MODULES)

DEFRE = re.compile(
    r'^    \(define(?:-record-type|-syntax|-values|-constant|-parameter)?\s+\(?([^\s()]+)')


def r7rs_exports():
    """Every name the R7RS modules export, as a map from name to module.

    The module is kept so the report can name the one that actually
    clashes: the message used to say `(scheme base)' for every hit, which
    sent the reader to the wrong list for anything from `(scheme file)'.
    """
    out = subprocess.run(
        ['guile', '--no-auto-compile', '-L', REPO, '-c', DUMP],
        capture_output=True, text=True,
        env=dict(os.environ, GUILE_WARN_DEPRECATED='no')).stdout
    names = {}
    for line in out.split('\n'):
        if '\t' not in line:
            continue
        module, exports = line.split('\t', 1)
        for name in exports.split():
            names.setdefault(name, module)
    if not names:
        sys.exit('could not read the R7RS export lists from guile')
    return names


def balanced(src, start):
    """The index just past the form that opens at START, an index of `('."""
    depth, i = 0, start
    while i < len(src):
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(src)


def excepted_names(src):
    """The names this file imports with `(except LIB NAME ...)'.

    Only the names *after* the library spec count: the spec's own
    components are ordinary symbols too, and taking them would swallow a
    definition of, say, `file'.
    """
    out = set()
    i = src.find('(except')
    while i >= 0:
        end = balanced(src, i)
        rest = src[i + len('(except'):end - 1].lstrip()
        if rest.startswith('('):
            rest = rest[balanced(rest, 0):]
        else:
            rest = rest.split(None, 1)[1] if len(rest.split(None, 1)) > 1 else ''
        out |= set(re.findall(r'[^\s()]+', rest))
        i = src.find('(except', end)
    return out


def library_files():
    """The libraries, and not the test suites that live beside them.

    The two were told apart by extension while the libraries were `.sld'
    (a suite is a script - it `import's, it does not `define-library') and
    now everything here is `.scm', so it takes the name.
    """
    return sorted(p for p in glob.glob(
        os.path.join(REPO, 'schemacs/**/*.scm'), recursive=True)
        if not p.endswith('-tests.scm'))


def main():
    r7rs = r7rs_exports()
    paths = library_files()
    reported = 0
    for path in paths:
        src = open(path).read()
        start = src.find('\n  (begin')
        if start < 0:
            continue
        excepted = excepted_names(src)
        body = src[start:]
        for line in body.split('\n'):
            m = DEFRE.match(line)
            if m and m.group(1) in r7rs and m.group(1) not in excepted:
                print('%s: defines `%s\', which %s also exports - '
                      'the definition will be lost' % (
                          os.path.relpath(path, REPO), m.group(1),
                          r7rs[m.group(1)]))
                reported += 1
    if reported:
        print()
        print('Export such a name by rename from a differently-spelled '
              'definition; see newline-command in schemacs/editor/simple.scm, '
              'or except it as files.scm does for delete-file')
        return 1
    print('ok: no definition shadows an imported name (%d checked)'
          % len(paths))
    return 0


if __name__ == '__main__':
    sys.exit(main())
